import AppKit
import AVFoundation
import SwiftUI
import WebKit

/// The WebRTC side of calls, run by WebKit as the web runs it in the browser, so both ends speak the same SDP. The page
/// never touches the network: the call center signals over the signed API and hands it the offers and answers. One
/// peer connection per person, so a 1:1 call is a mesh of one. The page also draws the video tiles, and the call
/// views lend it a place on screen while a camera is on.
@MainActor
final class CallEngine: NSObject {
    enum Event {
        case connected(peer: String, code: String)
        case failed(peer: String)
        case closed(peer: String)
        case camera(peer: String, isOn: Bool)
        case height(CGFloat)
    }

    /// Why the page couldn't do what it was asked, by the DOMException's name: "NotAllowedError" when the microphone
    /// or camera was refused.
    struct Failure: Error {
        let name: String

        var isNotAllowed: Bool { name.contains("NotAllowedError") }
    }

    let webView: WKWebView
    var onEvent: (Event) -> Void = { _ in }

    /// Where the page waits while no call view shows it: a window that never comes on screen, so WebKit keeps playing
    /// the call's audio as for any page in a window.
    private let parking: NSWindow
    private var isLoaded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Nothing the page does is kept on disk.
        configuration.websiteDataStore = .nonPersistent()

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 1), configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")

        parking = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 480, height: 270), styleMask: .borderless, backing: .buffered, defer: false)
        parking.isReleasedWhenClosed = false
        parking.isExcludedFromWindowsMenu = true

        super.init()

        configuration.userContentController.add(MessageProxy(engine: self), name: "engine")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        parking.contentView?.addSubview(webView)
        // An https origin makes the page a secure context, which getUserMedia and crypto.subtle need.
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://localhost/"))
    }

    // MARK: - Calls into the page

    /// Gets the microphone and the relay settings ready for the peers about to open.
    func start(iceServers: [[String: Any]], isRelayOnly: Bool, mode: String) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure(name: "NotAllowedError") }

        try await run("await engine.start(iceServers, isRelayOnly, mode)", ["iceServers": iceServers, "isRelayOnly": isRelayOnly, "mode": mode])
    }

    /// Opens a peer that offers, and hands back its offer once the browser gathered every address, or after 3 s.
    func offer(_ peer: String, label: String) async throws -> String {
        try await run("return await engine.offer(peer, label)", ["peer": peer, "label": label]) as? String ?? ""
    }

    /// Opens a peer that answers the offer, and hands back the answer.
    func answer(_ peer: String, label: String, offer: String) async throws -> String {
        try await run("return await engine.answer(peer, label, sdp)", ["peer": peer, "label": label, "sdp": offer]) as? String ?? ""
    }

    func accept(_ peer: String, answer: String) async throws {
        try await run("await engine.accept(peer, sdp)", ["peer": peer, "sdp": answer])
    }

    func close(_ peer: String) {
        Task { try? await run("engine.close(peer)", ["peer": peer]) }
    }

    /// Hangs up on everyone and lets go of the microphone and the camera.
    func stop() {
        Task { try? await run("engine.stop()") }
    }

    func setMuted(_ isMuted: Bool) {
        Task { try? await run("engine.setMuted(isMuted)", ["isMuted": isMuted]) }
    }

    func setCamera(_ isOn: Bool) async throws {
        if isOn, !(await AVCaptureDevice.requestAccess(for: .video)) { throw Failure(name: "NotAllowedError") }

        try await run("await engine.setCamera(isOn)", ["isOn": isOn])
    }

    @discardableResult
    private func run(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        if !isLoaded {
            await withCheckedContinuation { waiters.append($0) }
        }

        // The completion handler, unlike the async variant, takes a page answering undefined.
        return try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case let .success(value):
                    continuation.resume(returning: value)
                case let .failure(error):
                    let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    continuation.resume(throwing: Failure(name: message))
                }
            }
        }
    }

    // MARK: - Showing the video

    func attach(to host: NSView) {
        guard webView.superview !== host else { return }

        webView.removeFromSuperview()
        webView.frame = host.bounds
        host.addSubview(webView)
    }

    func detach(from host: NSView) {
        guard webView.superview === host else { return }

        webView.removeFromSuperview()
        webView.frame = parking.contentView?.bounds ?? .zero
        parking.contentView?.addSubview(webView)
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }

        let peer = message["peer"] as? String ?? ""

        switch type {
        case "connected": onEvent(.connected(peer: peer, code: message["code"] as? String ?? ""))
        case "failed": onEvent(.failed(peer: peer))
        case "closed": onEvent(.closed(peer: peer))
        case "camera": onEvent(.camera(peer: peer, isOn: message["on"] as? Bool ?? false))
        case "height": onEvent(.height(message["value"] as? CGFloat ?? 0))
        default: break
        }
    }
}

extension CallEngine: WKUIDelegate, WKNavigationDelegate {
    /// The app already asked macOS for the microphone or camera; the page gets them without asking again.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Holds the engine weakly, since the content controller keeps its handlers for as long as the web view lives.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var engine: CallEngine?

    init(engine: CallEngine) {
        self.engine = engine
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { engine?.receive(message.body) }
    }
}

/// Lends the engine's page a place in a view while a camera is on in the call.
struct CallVideoView: NSViewRepresentable {
    let engine: CallEngine

    final class Host: NSView {
        weak var engine: CallEngine?
    }

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.engine = engine
        return host
    }

    func updateNSView(_ host: Host, context: Context) {
        engine.attach(to: host)
    }

    static func dismantleNSView(_ host: Host, coordinator: ()) {
        host.engine?.detach(from: host)
    }
}

extension CallEngine {
    /// The call's WebRTC, as resources/js/lib/call.ts and org-call.ts run it on the web: non-trickle ICE, a video
    /// transceiver from the start so the camera goes on without renegotiating, and a "call" data channel saying when it
    /// does, which closing also tells the other side the call ended.
    static let page = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
        html, body { margin: 0; background: transparent; overflow: hidden; }
        #grid { display: none; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
        #grid.org { grid-template-columns: repeat(var(--columns, 2), minmax(0, 1fr)); }
        .tile { position: relative; aspect-ratio: 16 / 9; overflow: hidden; border-radius: 6px; background: #171717; }
        .tile.partner { box-shadow: inset 0 0 0 2px rgba(59, 111, 224, 0.6); }
        .tile video { width: 100%; height: 100%; object-fit: cover; }
        .tile video.mirrored { transform: scaleX(-1); }
        .tile span { position: absolute; left: 6px; bottom: 6px; max-width: calc(100% - 12px); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; border-radius: 4px; background: rgba(0, 0, 0, 0.6); padding: 2px 6px; color: #fff; font: 11px ui-monospace, Menlo, monospace; }
    </style>
    </head>
    <body>
    <div id="grid"></div>
    <script>
    const post = (message) => window.webkit.messageHandlers.engine.postMessage(message);
    const peers = new Map();
    let config = {};
    let mode = 'direct';
    let microphone = null;
    let camera = null;

    function named(error) {
        return new Error(error && error.name ? error.name : String(error));
    }

    function videoOf(connection) {
        return connection.getTransceivers().find((transceiver) => transceiver.receiver.track.kind === 'video');
    }

    function sendCamera(peer) {
        if (peer.channel && peer.channel.readyState === 'open') {
            peer.channel.send(JSON.stringify({ camera: camera !== null }));
        }
    }

    function gathered(connection) {
        return new Promise((resolve) => {
            const done = () => resolve(connection.localDescription ? connection.localDescription.sdp : '');

            if (connection.iceGatheringState === 'complete') {
                done();
                return;
            }

            const timer = setTimeout(done, 3000);
            connection.addEventListener('icegatheringstatechange', () => {
                if (connection.iceGatheringState === 'complete') {
                    clearTimeout(timer);
                    done();
                }
            });
        });
    }

    async function verificationCode(connection) {
        const fingerprints = [connection.localDescription && connection.localDescription.sdp, connection.remoteDescription && connection.remoteDescription.sdp]
            .map((sdp) => { const match = /a=fingerprint:(.+)/.exec(sdp || ''); return match && match[1] ? match[1].trim() : ''; })
            .toSorted()
            .join('|');
        const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(fingerprints)));
        const hex = Array.from(digest.slice(0, 4), (byte) => byte.toString(16).padStart(2, '0')).join('');

        return `${hex.slice(0, 4)} ${hex.slice(4)}`;
    }

    function open(id, label, isOfferer) {
        close(id);

        const connection = new RTCPeerConnection(config);
        const peer = { connection, channel: null, label, isCameraOn: false, video: null, speaker: new Audio() };
        peers.set(id, peer);

        if (microphone) {
            microphone.getTracks().forEach((track) => connection.addTrack(track, microphone));
        }

        connection.ontrack = (event) => {
            if (event.track.kind === 'video') {
                peer.video = new MediaStream([event.track]);
                render();
                return;
            }

            peer.speaker.srcObject = new MediaStream([event.track]);
            peer.speaker.play().catch(() => undefined);
        };

        const watch = (channel) => {
            peer.channel = channel;
            channel.onopen = () => sendCamera(peer);
            channel.onclose = () => {
                if (peers.get(id) === peer) {
                    close(id);
                    post({ type: 'closed', peer: id });
                }
            };
            channel.onmessage = (event) => {
                try {
                    const message = typeof event.data === 'string' ? JSON.parse(event.data) : null;

                    if (peers.get(id) === peer && message && typeof message.camera === 'boolean') {
                        peer.isCameraOn = message.camera;
                        render();
                        post({ type: 'camera', peer: id, on: message.camera });
                    }
                } catch (error) {
                    // Not a message this app knows.
                }
            };
        };

        if (isOfferer) {
            const video = connection.addTransceiver('video', { direction: 'sendrecv' });
            video.sender.replaceTrack(camera ? camera.getVideoTracks()[0] : null).catch(() => undefined);
            watch(connection.createDataChannel('call'));
        } else {
            connection.ondatachannel = (event) => watch(event.channel);
        }

        connection.onconnectionstatechange = async () => {
            if (peers.get(id) !== peer) {
                return;
            }

            if (connection.connectionState === 'connected') {
                const code = await verificationCode(connection);

                if (peers.get(id) === peer) {
                    post({ type: 'connected', peer: id, code });
                }
            } else if (connection.connectionState === 'failed') {
                close(id);
                post({ type: 'failed', peer: id });
            }
        };

        return peer;
    }

    function close(id) {
        const peer = peers.get(id);

        if (!peer) {
            return;
        }

        peers.delete(id);
        peer.connection.close();
        peer.speaker.srcObject = null;
        render();
    }

    function render() {
        const grid = document.getElementById('grid');
        const others = [...peers.values()];
        const cameras = mode === 'direct' ? others : others.filter((peer) => peer.isCameraOn);
        const isShown = camera !== null || others.some((peer) => peer.isCameraOn);

        grid.className = mode === 'org' ? 'org' : '';
        grid.style.setProperty('--columns', document.body.clientWidth >= 640 ? '3' : '2');
        grid.style.display = isShown ? 'grid' : 'none';
        grid.replaceChildren();

        if (isShown) {
            cameras.forEach((peer) => grid.append(tile(peer.isCameraOn ? peer.video : null, mode === 'direct' ? `${peer.label} · ${peer.isCameraOn ? 'cam' : 'cam off'}` : peer.label, false, mode === 'direct')));
            grid.append(tile(camera, camera !== null ? 'you · cam' : 'you · cam off', true, false));
        }

        post({ type: 'height', value: isShown ? grid.getBoundingClientRect().height : 0 });
    }

    function tile(stream, label, isMirrored, isPartner) {
        const element = document.createElement('div');
        element.className = isPartner ? 'tile partner' : 'tile';

        if (stream) {
            const video = document.createElement('video');
            video.autoplay = true;
            video.playsInline = true;
            video.muted = true;
            video.srcObject = stream;

            if (isMirrored) {
                video.className = 'mirrored';
            }

            element.append(video);
        }

        const caption = document.createElement('span');
        caption.textContent = label;
        element.append(caption);

        return element;
    }

    new ResizeObserver(() => render()).observe(document.body);

    window.engine = {
        async start(iceServers, isRelayOnly, nextMode) {
            mode = nextMode;
            // Only through the relay when the server says so: a direct route would hand each person the others' IP addresses.
            config = { iceServers, iceTransportPolicy: isRelayOnly ? 'relay' : 'all' };

            if (!microphone) {
                try {
                    microphone = await navigator.mediaDevices.getUserMedia({ audio: true });
                } catch (error) {
                    throw named(error);
                }
            }
        },
        async offer(id, label) {
            const peer = open(id, label, true);
            await peer.connection.setLocalDescription(await peer.connection.createOffer());

            return await gathered(peer.connection);
        },
        async answer(id, label, sdp) {
            const peer = open(id, label, false);
            await peer.connection.setRemoteDescription({ type: 'offer', sdp });
            const video = videoOf(peer.connection);

            if (video) {
                video.direction = 'sendrecv';
                await video.sender.replaceTrack(camera ? camera.getVideoTracks()[0] : null);
            }

            await peer.connection.setLocalDescription(await peer.connection.createAnswer());

            return await gathered(peer.connection);
        },
        async accept(id, sdp) {
            const peer = peers.get(id);

            if (peer) {
                await peer.connection.setRemoteDescription({ type: 'answer', sdp });
            }
        },
        close,
        stop() {
            [...peers.keys()].forEach(close);
            [microphone, camera].forEach((stream) => stream && stream.getTracks().forEach((track) => track.stop()));
            microphone = null;
            camera = null;
            render();
        },
        setMuted(isMuted) {
            if (microphone) {
                microphone.getAudioTracks().forEach((track) => { track.enabled = !isMuted; });
            }
        },
        async setCamera(isOn) {
            if (!isOn && camera) {
                camera.getTracks().forEach((track) => track.stop());
                camera = null;
            } else if (isOn && !camera) {
                try {
                    camera = await navigator.mediaDevices.getUserMedia({ video: true });
                } catch (error) {
                    throw named(error);
                }
            }

            await Promise.all([...peers.values()].map(async (peer) => {
                const video = videoOf(peer.connection);

                if (video) {
                    await video.sender.replaceTrack(camera ? camera.getVideoTracks()[0] : null).catch(() => undefined);
                }

                sendCamera(peer);
            }));
            render();
        },
    };
    </script>
    </body>
    </html>
    """#
}
