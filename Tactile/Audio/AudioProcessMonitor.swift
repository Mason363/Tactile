//
//  AudioProcessMonitor.swift
//  Tactile
//

import AppKit
import CoreAudio

/// Who is playing or recording audio right now, straight from Core Audio's
/// own bookkeeping. No audio is read and no permission is needed: every
/// audio client has a process object whose flags say whether it is running
/// output (playing) or input (recording).
///
/// Those two flags can be read but never notify. What does notify is the
/// process's overall "running" flag (IO started or stopped) and each
/// device's "running somewhere" (any client starting IO on it, which also
/// catches an app adding the microphone while it already plays). Either
/// event re-reads the precise flags, so this stays listener-driven and
/// costs nothing while nothing changes.
///
/// Sound alerts use it to feel an app start making sound; music haptics use
/// it to run the audio tap only while something plays, and to notice a call
/// holding the microphone.
///
/// Threading: Core Audio state is confined to a private queue; `playing`,
/// `recording`, and `onChange` belong to the main thread.
nonisolated final class AudioProcessMonitor: @unchecked Sendable {
    /// One audio client, attributed to the app responsible for it: a
    /// browser's audio helper counts as the browser, WebKit's media process
    /// as Safari.
    struct Client: Hashable, Sendable {
        let pid: pid_t
        /// The responsible app's bundle ID, falling back to the process's own.
        let appBundleID: String?
        /// The process's own bundle ID, e.g. "com.google.Chrome.helper".
        let processBundleID: String?
        /// The responsible app is a Dock app, not a daemon or an agent.
        let isRegularApp: Bool
    }

    /// Main thread: who plays or records changed. The first call after
    /// `start()` is the initial snapshot.
    var onChange: (@MainActor () -> Void)?

    /// Main thread: clients playing / recording right now.
    private(set) var playing: Set<Client> = []
    private(set) var recording: Set<Client> = []

    /// Main thread.
    private(set) var isRunning = false
    private var mainGeneration = 0

    private let queue = DispatchQueue(label: "com.masonchen.Tactile.audio-clients")

    private struct Entry {
        let client: Client
        var output: Bool
        var input: Bool
        let listener: AudioObjectPropertyListenerBlock
    }

    // Queue-confined.
    private var entries: [AudioObjectID: Entry] = [:]
    private var ignored: Set<AudioObjectID> = []
    private var systemListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var attached = false
    private var generation = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true
        mainGeneration += 1
        let generation = mainGeneration
        queue.async { self.attach(generation) }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        mainGeneration += 1
        playing = []
        recording = []
        queue.async { self.detach() }
    }

    // MARK: - Queue

    private func attach(_ generation: Int) {
        self.generation = generation
        attached = true
        // Apps arriving and leaving, and devices coming and going.
        listenToSystem(kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refresh() }
        listenToSystem(kAudioHardwarePropertyDevices) { [weak self] in self?.refreshDevices() }
        refreshDevices()
        refresh(force: true)
    }

    private func detach() {
        attached = false
        for (selector, block) in systemListeners {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(Self.system, &address, queue, block)
        }
        systemListeners = []
        for (device, block) in deviceListeners {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
        deviceListeners = [:]
        for (id, entry) in entries {
            var address = Self.address(kAudioProcessPropertyIsRunning)
            AudioObjectRemovePropertyListenerBlock(id, &address, queue, entry.listener)
        }
        entries = [:]
        ignored = []
    }

    private func listenToSystem(_ selector: AudioObjectPropertySelector, _ action: @escaping () -> Void) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
        if AudioObjectAddPropertyListenerBlock(Self.system, &address, queue, block) == noErr {
            systemListeners.append((selector, block))
        }
    }

    /// Any device starting IO for anyone: re-read every client's flags.
    private func refreshDevices() {
        guard attached else { return }
        let devices = Set(Self.objects(Self.system, kAudioHardwarePropertyDevices))
        for (device, block) in deviceListeners where !devices.contains(device) {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
            deviceListeners[device] = nil
        }
        for device in devices where deviceListeners[device] == nil {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
            if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
                deviceListeners[device] = block
            }
        }
    }

    private func refresh(force: Bool = false) {
        guard attached else { return }
        let ids = Set(Self.objects(Self.system, kAudioHardwarePropertyProcessObjectList))
        var changed = force
        for (id, entry) in entries where !ids.contains(id) {
            var address = Self.address(kAudioProcessPropertyIsRunning)
            AudioObjectRemovePropertyListenerBlock(id, &address, queue, entry.listener)
            entries[id] = nil
            changed = changed || entry.output || entry.input
        }
        ignored.formIntersection(ids)
        for id in ids where entries[id] == nil && !ignored.contains(id) {
            // Tactile's own clicks are not news.
            guard let client = Self.client(for: id), client.pid != Self.ownPID else {
                ignored.insert(id)
                continue
            }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.flagsChanged(id) }
            var address = Self.address(kAudioProcessPropertyIsRunning)
            AudioObjectAddPropertyListenerBlock(id, &address, queue, listener)
            // Read after listening, so a flip in between can't be missed.
            let entry = Entry(
                client: client,
                output: Self.flag(id, kAudioProcessPropertyIsRunningOutput),
                input: Self.flag(id, kAudioProcessPropertyIsRunningInput),
                listener: listener
            )
            entries[id] = entry
            changed = changed || entry.output || entry.input
        }
        if changed { publish() }
    }

    private func flagsChanged(_ id: AudioObjectID) {
        guard attached, var entry = entries[id] else { return }
        let output = Self.flag(id, kAudioProcessPropertyIsRunningOutput)
        let input = Self.flag(id, kAudioProcessPropertyIsRunningInput)
        guard output != entry.output || input != entry.input else { return }
        entry.output = output
        entry.input = input
        entries[id] = entry
        publish()
    }

    private func rescan() {
        guard attached else { return }
        var changed = false
        for (id, entry) in entries {
            let output = Self.flag(id, kAudioProcessPropertyIsRunningOutput)
            let input = Self.flag(id, kAudioProcessPropertyIsRunningInput)
            guard output != entry.output || input != entry.input else { continue }
            entries[id]?.output = output
            entries[id]?.input = input
            changed = true
        }
        if changed { publish() }
    }

    private func publish() {
        let playing = Set(entries.values.filter(\.output).map(\.client))
        let recording = Set(entries.values.filter(\.input).map(\.client))
        let generation = self.generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, self.mainGeneration == generation else { return }
            self.playing = playing
            self.recording = recording
            MainActor.assumeIsolated { self.onChange?() }
        }
    }

    // MARK: - Core Audio

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let ownPID = getpid()

    private typealias ResponsibleFunc = @convention(c) (pid_t) -> pid_t
    /// The system's responsibility lookup, the one Activity Monitor uses to
    /// group helpers under their app. Without it every process is its own
    /// owner, and helpers still match their app by bundle-ID prefix.
    private static let responsible: ResponsibleFunc? = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"
    ).map { unsafeBitCast($0, to: ResponsibleFunc.self) }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func objects(_ owner: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(owner, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(owner, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// A read failure (the process just exited) counts as off.
    private static func flag(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func client(for id: AudioObjectID) -> Client? {
        var address = address(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pid) == noErr, pid > 0 else { return nil }

        var bundleAddress = self.address(kAudioProcessPropertyBundleID)
        var bundle: Unmanaged<CFString>?
        var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var own: String?
        if AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr, let bundle {
            let value = bundle.takeRetainedValue() as String
            own = value.isEmpty ? nil : value
        }

        let owner = responsible.map { $0(pid) }.flatMap { $0 > 0 ? $0 : nil } ?? pid
        let app = NSRunningApplication(processIdentifier: owner)
        return Client(
            pid: pid,
            appBundleID: app?.bundleIdentifier ?? own,
            processBundleID: own,
            isRegularApp: app?.activationPolicy == .regular
        )
    }
}
