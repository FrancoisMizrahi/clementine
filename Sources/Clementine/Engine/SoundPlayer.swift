import AppKit

/// Plays UI sounds without ever blocking the main thread. Starting a sound can take 300 to 500 ms on the
/// calling thread when the audio route has gone idle (Bluetooth headphones especially), so every play
/// happens on a serial background queue, each sound has a small pool so overlapping plays never restart
/// one that is still sounding, and the route is woken once at launch.
final class SoundPlayer {
    enum Sound: String {
        case highlight = "Tink"
        case done = "Glass"
        case failed = "Basso"
        var volume: Float {
            switch self {
            case .highlight: return 0.25
            case .done: return 0.4
            case .failed: return 0.5
            }
        }
    }

    static let shared = SoundPlayer()
    private let queue = DispatchQueue(label: "clementine.sound", qos: .userInteractive)
    private var pools: [Sound: [NSSound]] = [:]
    private let poolSize = 3

    func prewarm() {
        queue.async {
            for sound in [Sound.highlight, .done] {
                guard let s = self.instances(for: sound).first else { continue }
                s.volume = 0
                s.play()
            }
        }
    }

    func play(_ sound: Sound) {
        guard Settings.shared.playSounds else { return }
        queue.async {
            guard let free = self.instances(for: sound).first(where: { !$0.isPlaying }) else { return }
            free.volume = sound.volume
            free.play()
        }
    }

    private func instances(for sound: Sound) -> [NSSound] {
        if let pool = pools[sound] { return pool }
        guard let base = NSSound(named: NSSound.Name(sound.rawValue)) else { return [] }
        var pool = [base]
        for _ in 1..<poolSize { if let copy = base.copy() as? NSSound { pool.append(copy) } }
        pools[sound] = pool
        return pool
    }
}
