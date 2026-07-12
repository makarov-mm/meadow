import Foundation

struct Frame {
    var tick: UInt32
    var grassW: Int
    var grassH: Int
    var grass: [UInt8]
    var agents: [AgentWire]
    var events: [EventWire]
}

struct AgentWire {
    var id: UInt16
    var species: UInt8  // 0 herbivore, 1 predator, 2 bush
    var state: UInt8    // 0 head down, 1 walk, 2 run, 3 dead, 4 idle, 5 eat
    var scale: Float    // model scale for animals, berry fill for bushes
    var x: Float
    var z: Float
    var heading: Float
}

struct EventWire {
    var type: UInt8     // 0 kill, 1 birth, 2 starve, 3 berry, 4 hunt
    var aux: UInt8
    var x: Float
    var z: Float
}

/// Connects to the Elixir server, decodes binary frames, hands them to World.
final class Net: NSObject {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private let url: URL
    private weak var world: World?

    init(world: World, host: String, port: Int) {
        self.world = world
        self.url = URL(string: "ws://\(host):\(port)/")!
        super.init()
        session = URLSession(configuration: .default)
    }

    func start() { connect() }

    private func connect() {
        task = session.webSocketTask(with: url)
        task?.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .data(let data) = message {
                    self.decode(data)
                }
                self.receive()
            case .failure:
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.connect()
                }
            }
        }
    }

    private func decode(_ data: Data) {
        guard data.count >= 10 else { return }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            var off = 0

            func u8() -> UInt8 { defer { off += 1 }; return base.load(fromByteOffset: off, as: UInt8.self) }
            func u16() -> UInt16 {
                let v = base.loadUnaligned(fromByteOffset: off, as: UInt16.self)
                off += 2
                return UInt16(littleEndian: v)
            }
            func i16() -> Int16 { Int16(bitPattern: u16()) }
            func u32() -> UInt32 {
                let v = base.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                off += 4
                return UInt32(littleEndian: v)
            }

            let tick = u32()
            let nAgents = Int(u16())
            let nEvents = Int(u16())
            let gw = Int(u8())
            let gh = Int(u8())

            guard data.count >= 10 + gw * gh + nAgents * 10 + nEvents * 8 else { return }

            var grass = [UInt8](repeating: 0, count: gw * gh)
            for i in 0..<(gw * gh) { grass[i] = u8() }

            var agents = [AgentWire]()
            agents.reserveCapacity(nAgents)
            for _ in 0..<nAgents {
                let id = u16()
                let flags = u8()
                let sc = u8()
                let x = Float(i16()) / 64.0
                let z = Float(i16()) / 64.0
                let heading = Float(i16()) / 10430.0
                agents.append(AgentWire(
                    id: id,
                    species: flags & 3,
                    state: (flags >> 2) & 7,
                    scale: Float(sc) / 200.0,
                    x: x, z: z, heading: heading
                ))
            }

            var events = [EventWire]()
            events.reserveCapacity(nEvents)
            for _ in 0..<nEvents {
                let type = u8()
                let aux = u8()
                let x = Float(i16()) / 64.0
                let z = Float(i16()) / 64.0
                _ = u16()
                events.append(EventWire(type: type, aux: aux, x: x, z: z))
            }

            world?.ingest(Frame(tick: tick, grassW: gw, grassH: gh, grass: grass,
                                agents: agents, events: events))
        }
    }
}
