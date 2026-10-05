//
//  TransferDelegate.swift
//  DownloadKit
//
//  The URLSession delegate boundary. URLSession calls it on a serial operation queue and
//  requires it to be Sendable; it holds only immutable values. It does the two things that
//  must happen before a callback returns (deciding about a finished response and moving its
//  temporary file into `staging/` with a durable receipt) and forwards everything, in callback
//  order, through one AsyncStream continuation to the session's actor. That single ordered
//  channel is the ingestion mechanism: no callback starts its own task, so arrival order is the
//  callback order.
//

import Foundation

/// A delegate callback, translated into an immutable value.
enum DelegateCallback: Sendable {
    case progress(taskIdentifier: Int, description: String?, written: Int64, expected: Int64)
    case waiting(taskIdentifier: Int, description: String?)
    /// A terminal outcome decided inside `didFinishDownloadingTo`. `durable` is false when its
    /// receipt could not be written; the session then has to store the event before anything
    /// else is delivered.
    case receipt(CaptureReceipt, taskIdentifier: Int, durable: Bool)
    /// The continuation of a resumed task cannot be trusted; start it again from zero.
    /// `request` is the system's copy of the task's request, used when the submission is not
    /// known in this process (the task was created before a relaunch).
    case restart(taskIdentifier: Int, description: String?, request: URLRequest? = nil)
    case completed(taskIdentifier: Int, description: String?, failure: TransferFailure?)
    /// The system delivered every event of a background wake
    /// (`urlSessionDidFinishEvents(forBackgroundURLSession:)`).
    case eventsFinished
    /// Every callback queued before this one has been forwarded.
    case barrier(UUID)
    case invalidated
}

/// Moves a finished download into `staging/` and records the outcome, synchronously.
struct FileCapture: Sendable {
    enum Outcome: Sendable {
        case receipt(CaptureReceipt, durable: Bool)
        /// The restart intent was written (`durable`) or only lives in memory.
        case restart(durable: Bool)
    }

    let storageRoot: URL
    let inbox: TransferInbox
    let inspector: ResponseInspector
    let now: @Sendable () -> Date

    /// Runs inside `didFinishDownloadingTo`, before it returns: `location` is only valid until
    /// then. A rejected response leaves the temporary file to the system, which deletes it.
    ///
    /// For accepted media the receipt naming the staging file is written first; only then is
    /// the file moved. A file in `staging/` therefore always has a durable association with its
    /// item and attempt. When the receipt cannot be written nothing is moved and the attempt
    /// ends with a storage failure: a capture is never claimed without its association.
    func capture(location: URL, response: URLResponse?, request: URLRequest?, reference: TransferTaskReference) -> Outcome {
        guard let http = response as? HTTPURLResponse else {
            return record(.failed(reference, .invalidResponse))
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let evidence = ResponseEvidence(
            statusCode: http.statusCode,
            headers: Self.headers(of: http),
            requestRange: request?.value(forHTTPHeaderField: "Range"),
            requestIfRange: request?.value(forHTTPHeaderField: "If-Range"),
            fileSize: size,
            leadingBytes: Self.leadingBytes(of: location)
        )
        switch inspector.inspect(evidence, now: now()) {
        case .restart:
            // Recorded before the callback returns, so a relaunch knows the refused task was
            // replaced rather than failed.
            let intent = RestartIntent(taskIdentifier: reference.taskIdentifier, itemID: reference.itemID.rawValue, generation: reference.generation, replacement: nil)
            return .restart(durable: (try? inbox.write(intent)) != nil)
        case .fail(let failure):
            return record(.failed(reference, failure))
        case .accept(let validators, let bytes):
            let stagingPath = RelativePath.staging()
            let destination: URL
            do {
                destination = try inbox.confined(storageRoot.appendingPathComponent(stagingPath.rawValue, isDirectory: false))
            } catch {
                return record(.failed(reference, .storage(DownloadFileSystemError(error).storageReason)))
            }
            let finished = TransferEvent.finished(reference, captured: stagingPath, bytes: bytes, validators: validators)
            // Terminal events always have a stored form.
            let receipt = CaptureReceipt(id: UUID(), written: now(), event: StoredTransferEvent(finished)!)
            do {
                try inbox.write(receipt)
            } catch {
                return record(.failed(reference, .storage(DownloadFileSystemError(error).storageReason)))
            }
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                // Replace the receipt with the failure. If even that write fails, the stored
                // receipt names a capture that does not exist, which finalisation rejects.
                let failed = CaptureReceipt(id: receipt.id, written: receipt.written, event: StoredTransferEvent(.failed(reference, .storage(DownloadFileSystemError(error).storageReason)))!)
                return .receipt(failed, durable: (try? inbox.write(failed)) != nil)
            }
            return .receipt(receipt, durable: true)
        }
    }

    /// Writes the receipt of an outcome that moved no file. If the write fails the session
    /// still has to store the event before it delivers anything else.
    private func record(_ event: TransferEvent) -> Outcome {
        let receipt = CaptureReceipt(id: UUID(), written: now(), event: StoredTransferEvent(event)!)
        return .receipt(receipt, durable: (try? inbox.write(receipt)) != nil)
    }

    private static let inspectedHeaders = ["Content-Type", "Content-Length", "Content-Range", "ETag", "Last-Modified", "Retry-After", "Date"]

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for name in inspectedHeaders {
            if let value = response.value(forHTTPHeaderField: name) { result[name.lowercased()] = value }
        }
        return result
    }

    private static func leadingBytes(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: ResponseInspector.sniffLength)) ?? Data()
    }
}

/// The delegate of the package's URLSession.
final class TransferDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let sessionIdentifier: String
    private let channel: AsyncStream<DelegateCallback>.Continuation
    private let capture: FileCapture

    init(sessionIdentifier: String, channel: AsyncStream<DelegateCallback>.Continuation, capture: FileCapture) {
        self.sessionIdentifier = sessionIdentifier
        self.channel = channel
        self.capture = capture
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // A task this package did not create, or one naming another session, is never
        // touched: its file is left to the system.
        guard let reference = TransferTaskReference(taskDescription: downloadTask.taskDescription, taskIdentifier: downloadTask.taskIdentifier, sessionIdentifier: sessionIdentifier) else { return }
        let outcome = capture.capture(
            location: location,
            response: downloadTask.response,
            request: downloadTask.currentRequest ?? downloadTask.originalRequest,
            reference: reference
        )
        switch outcome {
        case .receipt(let receipt, let durable):
            channel.yield(.receipt(receipt, taskIdentifier: downloadTask.taskIdentifier, durable: durable))
        case .restart:
            channel.yield(.restart(taskIdentifier: downloadTask.taskIdentifier, description: downloadTask.taskDescription, request: downloadTask.originalRequest ?? downloadTask.currentRequest))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        channel.yield(.progress(taskIdentifier: downloadTask.taskIdentifier, description: downloadTask.taskDescription, written: totalBytesWritten, expected: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        channel.yield(.completed(taskIdentifier: task.taskIdentifier, description: task.taskDescription, failure: error.map(TransferErrorClassifier.classify)))
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        channel.yield(.waiting(taskIdentifier: task.taskIdentifier, description: task.taskDescription))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        completionHandler(ResponseInspector.allowsRedirect(from: original, to: request.url) ? request : nil)
    }

    /// Background sessions only: the system delivered every event of the wake. Called on the
    /// delegate queue after those events' callbacks, so it reaches the session's actor behind
    /// them.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        channel.yield(.eventsFinished)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        channel.yield(.invalidated)
        channel.finish()
    }
}
