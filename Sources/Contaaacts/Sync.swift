import Network

// A simple length prefixed framing for sync messages
class SyncProtocol: NWProtocolFramerImplementation {
	static let definition = NWProtocolFramer.Definition(implementation: SyncProtocol.self)

	static var label: String { return "contaaacts-sync" }

	required init(framer: NWProtocolFramer.Instance) { }
	func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { return .ready }
	func wakeup(framer: NWProtocolFramer.Instance) { }
	func stop(framer: NWProtocolFramer.Instance) -> Bool { return true }
	func cleanup(framer: NWProtocolFramer.Instance) { }

	func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
		// Write the length prefix (littlendian because then we can use Data.load(as:) to read it
        // in the real world this would probably be bigendian and in any case need to be much more
        // rigorous
        let len = withUnsafeBytes(of: UInt32(messageLength).littleEndian, Array.init)
		framer.writeOutput(data: len)

        // send the sync message bytes
		do {
			try framer.writeOutputNoCopy(length: messageLength)
		} catch let error {
			print("Hit error writing \(error)")
		}
	}

	func handleInput(framer: NWProtocolFramer.Instance) -> Int {
		while true {
            // parse the length prefix
            var messageLen: UInt32? = nil
            let headerSize = 4
			let parsed = framer.parseInput(minimumIncompleteLength: headerSize,
										   maximumLength: headerSize) { (buffer, isComplete) -> Int in
				guard let buffer = buffer else {
					return 0
				}
				if buffer.count < headerSize {
					return 0
				}
                messageLen = buffer.load(as: UInt32.self)
				return headerSize
			}

			guard parsed, let messageLen = messageLen else {
				return headerSize
			}

			// Create an object to deliver the message.
			let message = NWProtocolFramer.Message(instance: framer)
			// Deliver the body of the message, along with the message object.
			if !framer.deliverInputNoCopy(length: Int(messageLen), message: message, isComplete: true) {
				return 0
			}
		}
	}
}
