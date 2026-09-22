import CoreNFC
import Flutter
import UIKit
#if SWIFT_PACKAGE
import flutter_nfc_kit_session
#endif

// taken from StackOverflow
extension Data {
    struct HexEncodingOptions: OptionSet {
        let rawValue: Int
        static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
    }
    
    func hexEncodedString(options: HexEncodingOptions = [.upperCase]) -> String {
        let format = options.contains(.upperCase) ? "%02hhX" : "%02hhx"
        return map { String(format: format, $0) }.joined()
    }
}

func dataWithHexString(hex: String) -> Data {
    var hex = hex
    var data = Data()
    while hex.count > 0 {
        let subIndex = hex.index(hex.startIndex, offsetBy: 2)
        let c = String(hex[..<subIndex])
        hex = String(hex[subIndex...])
        var ch: UInt64 = 0
        Scanner(string: c).scanHexInt64(&ch)
        var char = UInt8(ch)
        data.append(&char, count: 1)
    }
    return data
}

public class FlutterNfcKitPlugin: NSObject, FlutterPlugin, NFCTagReaderSessionDelegate {
    var session: NFCTagReaderSession?
    var tag: NFCTag?
    var multipleTagMessage: String?
    private let pendingPoll = IOSPendingOperationController<FlutterResult>()
    private var activeOperationID: UInt64?
    private var finishResults: [FlutterResult] = []
    private var invalidationRequested = false
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_nfc_kit/method", binaryMessenger: registrar.messenger())
        let instance = FlutterNfcKitPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.publish(instance)
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        guard let activeSession = session, let operationID = activeOperationID else {
            return
        }

        let pendingResult = pendingPoll.take(operationID: operationID)
        let pendingFinishResults = finishResults

        session = nil
        activeOperationID = nil
        finishResults = []
        invalidationRequested = false
        tag = nil

        activeSession.invalidate()
        pendingResult?(FlutterError(code: "409", message: "Session canceled", details: nil))
        for finishResult in pendingFinishResults {
            finishResult(nil)
        }
    }
    
    // from FlutterPlugin
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "getNFCAvailability" {
            if NFCReaderSession.readingAvailable {
                result("available")
            } else {
                result("not_supported")
            }
        } else if call.method == "restartPolling" {
            if let session = session, !invalidationRequested {
                session.restartPolling()
                result(nil)
            } else {
                result(FlutterError(code: "404", message: "No active session", details: nil))
            }
        } else if call.method == "poll" {
            if session != nil {
                result(FlutterError(code: "429", message: "Polling operation already in progress", details: nil))
            } else {
                let arguments = call.arguments as! [String: Any?]
                let technologies = arguments["technologies"] as! Int
                // TODO: derive pollingOption from technology flags
                var pollingOption: NFCTagReaderSession.PollingOption = []
                if (technologies & 0x3) != 0 {
                    pollingOption.insert(.iso14443)
                }
                if (technologies & 0x4) != 0 {
                    pollingOption.insert(.iso18092)
                }
                if (technologies & 0x8) != 0 {
                    pollingOption.insert(.iso15693)
                }
                guard let operationID = pendingPoll.begin(result) else {
                    result(FlutterError(code: "429", message: "Polling operation already in progress", details: nil))
                    return
                }
                guard let newSession = NFCTagReaderSession(
                    pollingOption: pollingOption,
                    delegate: self,
                    queue: .main
                ) else {
                    pendingPoll.take(operationID: operationID)?(
                        FlutterError(code: "500", message: "Failed to create NFC session", details: nil)
                    )
                    return
                }
                session = newSession
                activeOperationID = operationID
                invalidationRequested = false
                finishResults = []
                if let alertMessage = arguments["iosAlertMessage"] as? String {
                    newSession.alertMessage = alertMessage
                }
                if let multipleTagMessage = arguments["iosMultipleTagMessage"] as? String {
                    self.multipleTagMessage = multipleTagMessage
                }
                newSession.begin()
            }
        } else if call.method == "transceive" {
            if tag != nil {
                let req = (call.arguments as? [String: Any?])?["data"]
                if req != nil, req is String || req is FlutterStandardTypedData {
                    var data: Data
                    switch req {
                    case let hexReq as String:
                        data = dataWithHexString(hex: hexReq)
                    case let binReq as FlutterStandardTypedData:
                        data = binReq.data
                    default:
                        result(FlutterError(code: "400", message: "No data specified", details: nil))
                        return
                    }
                    
                    if data.count == 0 {
                        result(FlutterError(code: "400", message: "Empty data specified", details: nil))
                        return
                    }
                    
                    switch tag {
                    case let .iso7816(tag):
                        let apdu: NFCISO7816APDU? = NFCISO7816APDU(data: data)
                        if apdu == nil {
                            result(FlutterError(code: "400", message: "APDU format error", details: nil))
                            return
                        }
                        tag.sendCommand(apdu: apdu!) { (response: Data, sw1: UInt8, sw2: UInt8, error: Error?) in
                            if let error = error {
                                result(FlutterError(code: "500", message: "Communication error with iso7816 tag", details: error.localizedDescription))
                            } else {
                                var response = response
                                response.append(contentsOf: [sw1, sw2])
                                if req is String {
                                    result(response.hexEncodedString())
                                } else {
                                    result(response)
                                }
                            }
                        }
                        
                    case let .feliCa(tag):
                        if data.count < 2 {
                            result(FlutterError(code: "400", message: "feliCa command format error", details: nil))
                            return
                        }
                        // the first byte in data is length, and iOS will add it for us, so skip it
                        tag.sendFeliCaCommand(commandPacket: data.advanced(by: 1)) { (response: Data, error: Error?) in
                            if let error = error {
                                result(FlutterError(code: "500", message: "Communication error with felica tag", details: error.localizedDescription))
                            } else {
                                if req is String {
                                    result(response.hexEncodedString())
                                } else {
                                    result(response)
                                }
                            }
                        }
                    case let .miFare(tag):
                        tag.sendMiFareCommand(commandPacket: data) { (response: Data, error: Error?) in
                            if let error = error {
                                result(FlutterError(code: "500", message: "Communication error with mifare tag", details: error.localizedDescription))
                            } else {
                                if req is String {
                                    result(response.hexEncodedString())
                                } else {
                                    result(response)
                                }
                            }
                        }
                    case let .iso15693(tag):
                        if data.count < 2 {
                            result(FlutterError(code: "400", message: "iso15693 command format error", details: nil))
                            return
                        }
                        if #available(iOS 14, *) {
                            // format: flag, command, [parameter, data]
                            tag.sendRequest(requestFlags: Int(data[0]), commandCode: Int(data[1]), data: data.advanced(by: 2)) { (res: Result<(NFCISO15693ResponseFlag, Data?), Error>) in
                                switch (res) {
                                case let .failure(err):
                                    result(FlutterError(code: "500", message: "Communication error", details: err.localizedDescription))
                                case let .success((flags, data)):
                                    var response = Data()
                                    response.append(flags.rawValue)
                                    if data != nil {
                                        response.append(data!)
                                    }
                                    if req is String {
                                        result(response.hexEncodedString())
                                    } else {
                                        result(response)
                                    }
                                }
                            }
                        } else {
                            result(FlutterError(code: "405", message: "Transceive for iso15693 not supported on iOS < 14.0", details: nil))
                            return
                        }
                    default:
                        result(FlutterError(code: "405", message: "Transceive not supported on this type of card", details: nil))
                    }
                } else {
                    result(FlutterError(code: "400", message: "Bad argument", details: nil))
                }
            } else {
                result(FlutterError(code: "406", message: "No tag polled", details: nil))
            }
        } else if call.method == "readBlock" {
            let arguments = call.arguments as! [String : Any?]
            if case let .iso15693(tag) = tag {
                let rawFlags = (arguments["iso15693Flags"] as? UInt8) ?? 0
                let extendedMode = (arguments["iso15693ExtendedMode"] as? Bool) ?? false
                let handler = { (dataBlock: Data, error: Error?) in
                    if let error = error {
                        result(FlutterError(code: "500", message: "Cannot read iso15693 tag", details: error.localizedDescription))
                    } else {
                        result(dataBlock)
                    }
                }
                if !extendedMode {
                    let blockNumber = arguments["index"] as! UInt8
                    tag.readSingleBlock(requestFlags: RequestFlag(rawValue: rawFlags), blockNumber: blockNumber, completionHandler: handler)
                } else {
                    let blockNumber = arguments["index"] as! Int
                    tag.extendedReadSingleBlock(requestFlags: RequestFlag(rawValue: rawFlags), blockNumber: blockNumber, completionHandler: handler)
                }
            }
            else if case let .miFare(tag) = tag {
                let blockNumber = arguments["index"] as! UInt8
                let commandPacket = Data([0x30, blockNumber]) // MiFARE Classic / Ultralight READ command
                tag.sendMiFareCommand(commandPacket: commandPacket) { (data, error) in
                    if let error = error {
                        result(FlutterError(code: "500", message: "Cannot read mifare tag", details: error.localizedDescription))
                    } else {
                        result(data)
                    }
                }
            }
            else {
                result(FlutterError(code: "405", message: "readBlock not supported on this type of card", details: nil))
            }
        } else if call.method == "writeBlock" {
            let arguments = call.arguments as! [String : Any?]
            let data = (arguments["data"] as! FlutterStandardTypedData).data
            if case let .iso15693(tag) = tag {
                let rawFlags = (arguments["iso15693Flags"] as? UInt8) ?? 0
                let extendedMode = (arguments["iso15693ExtendedMode"] as? Bool) ?? false
                let handler = { (error: Error?) in
                    if let error = error {
                        result(FlutterError(code: "500", message: "Cannot write iso15693 tag", details: error.localizedDescription))
                    } else {
                        result(nil)
                    }
                }
                if !extendedMode {
                    let blockNumber = arguments["index"] as! UInt8
                    tag.writeSingleBlock(requestFlags: RequestFlag(rawValue: rawFlags), blockNumber: blockNumber, dataBlock: data, completionHandler: handler)
                } else {
                    let blockNumber = arguments["index"] as! Int
                    tag.extendedWriteSingleBlock(requestFlags: RequestFlag(rawValue: rawFlags), blockNumber: blockNumber, dataBlock: data, completionHandler: handler)
                }
            } 
            else if case let .miFare(tag) = tag {
                let blockNumber = arguments["index"] as! UInt8
                let command = switch tag.mifareFamily {
                case .ultralight:
                    0xA2 // MiFARE Ultralight WRITE command
                default:
                    0xA0 // MiFARE Classic WRITE command
                } as UInt8
                let writeCommand = Data([command, blockNumber]) + data
                tag.sendMiFareCommand(commandPacket: writeCommand) { (response, error) in
                    if let error = error {
                        result(FlutterError(code: "500", message: "Cannot write mifare tag", details: error.localizedDescription))
                    } else {
                        result(nil)
                    }
                }
            }
            else {
                result(FlutterError(code: "405", message: "writeBlock not supported on this type of card", details: nil))
            }
        } else if call.method == "readNDEF" {
            if tag != nil {
                var ndefTag: NFCNDEFTag?
                switch tag {
                case let .iso7816(tag):
                    ndefTag = tag
                case let .miFare(tag):
                    ndefTag = tag
                case let .feliCa(tag):
                    ndefTag = tag
                case let .iso15693(tag):
                    ndefTag = tag
                default:
                    ndefTag = nil
                }
                if ndefTag != nil {
                    ndefTag!.readNDEF() { (msg: NFCNDEFMessage?, error: Error?) in
                        if let nfcError = error as? NFCReaderError, nfcError.errorCode == 403  {
                            // NDEF tag does not contain any NDEF message
                            result("[]")
                        } else if let error = error {
                            result(FlutterError(code: "500", message: "Read NDEF error", details: error.localizedDescription))
                        } else if let msg = msg {
                            var records: [[String: Any]] = []
                            
                            for record in msg.records {
                                var entry: [String: Any] = [:]
                                
                                entry["identifier"] = record.identifier.hexEncodedString()
                                entry["payload"] = record.payload.hexEncodedString()
                                entry["type"] = record.type.hexEncodedString()
                                switch record.typeNameFormat {
                                case NFCTypeNameFormat.absoluteURI:
                                    entry["typeNameFormat"] = "absoluteURI"
                                case NFCTypeNameFormat.empty:
                                    entry["typeNameFormat"] = "empty"
                                case NFCTypeNameFormat.media:
                                    entry["typeNameFormat"] = "media"
                                case NFCTypeNameFormat.nfcExternal:
                                    entry["typeNameFormat"] = "nfcExternal"
                                case NFCTypeNameFormat.nfcWellKnown:
                                    entry["typeNameFormat"] = "nfcWellKnown"
                                case NFCTypeNameFormat.unchanged:
                                    entry["typeNameFormat"] = "unchanged"
                                default:
                                    entry["typeNameFormat"] = "unknown"
                                }
                                
                                records.append(entry)
                            }
                            
                            let jsonData = try! JSONSerialization.data(withJSONObject: records)
                            let jsonString = String(data: jsonData, encoding: .utf8)
                            result(jsonString)
                        } else {
                            result(FlutterError(code: "500", message: "Impossible branch reached", details: nil))
                        }
                    }
                } else {
                    result(FlutterError(code: "405", message: "NDEF not supported on this type of card", details: nil))
                }
            } else {
                result(FlutterError(code: "406", message: "No tag polled", details: nil))
            }
        } else if call.method == "writeNDEF" {
            if tag != nil {
                var ndefTag: NFCNDEFTag?
                switch tag {
                case let .iso7816(tag):
                    ndefTag = tag
                case let .miFare(tag):
                    ndefTag = tag
                case let .feliCa(tag):
                    ndefTag = tag
                case let .iso15693(tag):
                    ndefTag = tag
                default:
                    ndefTag = nil
                }
                if ndefTag != nil {
                    let jsonString = (call.arguments as? [String: Any?])?["data"] as? String
                    let json = try? JSONSerialization.jsonObject(with: jsonString!.data(using: .utf8)!)
                    let recordList = json as? [[String: Any]]
                    if recordList != nil {
                        var records: [NFCNDEFPayload] = []
                        for record in recordList! {
                            let format: NFCTypeNameFormat?
                            switch record["typeNameFormat"] as! String {
                            case "absoluteURI":
                                format = NFCTypeNameFormat.absoluteURI
                            case "empty":
                                format = NFCTypeNameFormat.empty
                            case "nfcExternal":
                                format = NFCTypeNameFormat.nfcExternal
                            case "nfcWellKnown":
                                format = NFCTypeNameFormat.nfcWellKnown
                            case "media":
                                format = NFCTypeNameFormat.media
                            case "unchanged":
                                format = NFCTypeNameFormat.unchanged
                            default:
                                format = NFCTypeNameFormat.unknown
                            }
                            records.append(NFCNDEFPayload(
                                format: format!,
                                type: dataWithHexString(hex: record["type"] as! String),
                                identifier: dataWithHexString(hex: record["identifier"] as! String),
                                payload: dataWithHexString(hex: record["payload"] as! String)
                            ))
                        }
                        
                        ndefTag!.writeNDEF(NFCNDEFMessage(records: records)) { (error: Error?) in
                            if let error = error {
                                result(FlutterError(code: "500", message: "Write NDEF error", details: error.localizedDescription))
                            } else {
                                result(nil)
                            }
                        }
                    } else {
                        result(FlutterError(code: "400", message: "Bad argument", details: nil))
                    }
                } else {
                    result(FlutterError(code: "405", message: "NDEF not supported on this type of card", details: nil))
                }
            } else {
                result(FlutterError(code: "406", message: "No tag polled", details: nil))
            }
        } else if call.method == "finish" {
            if let session = session {
                finishResults.append(result)
                if invalidationRequested {
                    return
                }
                invalidationRequested = true
                tag = nil

                let arguments = call.arguments as! [String: Any?]
                let alertMessage = arguments["iosAlertMessage"] as? String
                let errorMessage = arguments["iosErrorMessage"] as? String
                
                if let errorMessage = errorMessage {
                    session.invalidate(errorMessage: errorMessage)
                } else {
                    if let alertMessage = alertMessage {
                        session.alertMessage = alertMessage
                    }
                    session.invalidate()
                }
            } else {
                tag = nil
                result(nil)
            }
        } else if call.method == "setIosAlertMessage" {
            if let session = session {
                if let alertMessage = call.arguments as? String {
                    session.alertMessage = alertMessage
                }
                result(nil)
            } else {
                result(FlutterError(code: "406", message: "Session not active", details: nil))
            }
        } else if call.method == "makeNdefReadOnly" {
            if tag != nil {
                var ndefTag: NFCNDEFTag?
                switch tag {
                case let .iso7816(tag):
                    ndefTag = tag
                case let .miFare(tag):
                    ndefTag = tag
                case let .feliCa(tag):
                    ndefTag = tag
                case let .iso15693(tag):
                    ndefTag = tag
                default:
                    ndefTag = nil
                }
                if ndefTag != nil {
                    ndefTag!.writeLock() { (error: Error?) in
                        if let error = error {
                            result(FlutterError(code: "500", message: "Lock NDEF error", details: error.localizedDescription))
                        } else {
                            result(nil)
                        }
                    }
                } else {
                    result(FlutterError(code: "405", message: "NDEF not supported on this type of card", details: nil))
                }
            } else {
                result(FlutterError(code: "406", message: "No tag polled", details: nil))
            }
        }
        else {
            result(FlutterMethodNotImplemented)
        }
    }
    
    // from NFCTagReaderSessionDelegate
    public func tagReaderSessionDidBecomeActive(_: NFCTagReaderSession) {}
    
    // from NFCTagReaderSessionDelegate
    public func tagReaderSession(_ invalidatedSession: NFCTagReaderSession, didInvalidateWithError error: Error) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard session === invalidatedSession, let operationID = activeOperationID else {
            return
        }

        let pendingResult = pendingPoll.take(operationID: operationID)
        let pendingFinishResults = finishResults
        let wasRequestedByFinish = invalidationRequested

        session = nil
        activeOperationID = nil
        finishResults = []
        invalidationRequested = false
        tag = nil

        if let pendingResult = pendingResult {
            if wasRequestedByFinish {
                pendingResult(FlutterError(code: "409", message: "Session canceled", details: error.localizedDescription))
            } else if let nfcError = error as? NFCReaderError {
                NSLog("Got NFCError when reading NFC: %@", nfcError.localizedDescription)
                switch nfcError.errorCode {
                case NFCReaderError.Code.readerSessionInvalidationErrorUserCanceled.rawValue:
                    pendingResult(FlutterError(code: "409", message: "SessionCanceled", details: error.localizedDescription))
                case NFCReaderError.Code.readerSessionInvalidationErrorSessionTimeout.rawValue:
                    pendingResult(FlutterError(code: "408", message: "SessionTimeOut", details: error.localizedDescription))
                default:
                    pendingResult(FlutterError(code: "500", message: "Generic NFC Error", details: error.localizedDescription))
                }
            } else {
                NSLog("Got unknown when reading NFC: %@", error.localizedDescription)
                pendingResult(FlutterError(code: "500", message: "Invalidate session with error", details: error.localizedDescription))
            }
        }

        for finishResult in pendingFinishResults {
            finishResult(nil)
        }
    }
    
    // from NFCTagReaderSessionDelegate
    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.session === session,
              let operationID = activeOperationID,
              !invalidationRequested else {
            return
        }

        if tags.count > 1 {
            // Restart polling in 500ms
            let retryInterval = DispatchTimeInterval.milliseconds(500)
            if multipleTagMessage != nil {
                session.alertMessage = multipleTagMessage!
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) { [weak self, weak session] in
                guard let self = self,
                      let session = session,
                      self.session === session,
                      self.activeOperationID == operationID,
                      !self.invalidationRequested else {
                    return
                }
                session.restartPolling()
            }
            return
        }
        
        let firstTag = tags.first!
        
        var result: [String: Any] = [:]
        // default NDEF status
        result["ndefAvailable"] = false
        result["ndefWritable"] = false
        result["ndefCapacity"] = 0
        // fake NDEF results
        result["ndefType"] = ""
        result["ndefCanMakeReadOnly"] = false
        
        switch firstTag {
        case let .iso7816(tag):
            result["type"] = "iso7816"
            result["id"] = tag.identifier.hexEncodedString()
            if let historicalBytes = tag.historicalBytes {
                result["historicalBytes"] = historicalBytes.hexEncodedString()
                result["standard"] = "ISO 14443-4 (Type A)"
            } else if let applicationData = tag.applicationData {
                result["applicationData"] = applicationData.hexEncodedString()
                result["standard"] = "ISO 14443-4 (Type B)"
            } else {
                result["standard"] = "ISO 14443"
            }
            result["aid"] = tag.initialSelectedAID
        case let .miFare(tag):
            switch tag.mifareFamily {
            case .plus:
                result["type"] = "mifare_plus"
                result["standard"] = "ISO 14443-4 (Type A)"
            case .ultralight:
                result["type"] = "mifare_ultralight"
                result["standard"] = "ISO 14443-3 (Type A)"
            case .desfire:
                result["type"] = "mifare_desfire"
                result["standard"] = "ISO 14443-4 (Type A)"
            default:
                result["type"] = "unknown"
                result["standard"] = "ISO 14443 (Type A)"
            }
            result["id"] = tag.identifier.hexEncodedString()
            result["historicalBytes"] = tag.historicalBytes?.hexEncodedString()
        case let .feliCa(tag):
            result["type"] = "iso18092"
            result["standard"] = "ISO 18092 (FeliCa)"
            result["id"] = tag.currentIDm.hexEncodedString()
            result["systemCode"] = tag.currentSystemCode.hexEncodedString()
        case let .iso15693(tag):
            result["type"] = "iso15693"
            result["standard"] = "ISO 15693"
            result["id"] = tag.identifier.hexEncodedString()
            result["manufacturer"] = String(format: "%d", tag.icManufacturerCode)
        default:
            result["type"] = "unknown"
            result["standard"] = "unknown"
            result["id"] = "unknown"
        }
        
        session.connect(to: firstTag) { (error: Error?) in
            dispatchPrecondition(condition: .onQueue(.main))
            guard self.session === session,
                  self.activeOperationID == operationID,
                  !self.invalidationRequested else {
                return
            }
            if let error = error {
                self.pendingPoll.take(operationID: operationID)?(
                    FlutterError(code: "500", message: "Error connecting to card", details: error.localizedDescription)
                )
                return
            }
            self.tag = firstTag
            
            var ndefTag: NFCNDEFTag?
            switch self.tag {
            case let .iso7816(tag):
                ndefTag = tag
            case let .miFare(tag):
                ndefTag = tag
            case let .feliCa(tag):
                ndefTag = tag
            case let .iso15693(tag):
                ndefTag = tag
            default:
                ndefTag = nil
            }
            
            if ndefTag != nil {
                ndefTag!.queryNDEFStatus() { (status: NFCNDEFStatus, capacity: Int, error: Error?) in
                    dispatchPrecondition(condition: .onQueue(.main))
                    guard self.session === session,
                          self.activeOperationID == operationID,
                          !self.invalidationRequested else {
                        return
                    }
                    if error == nil {
                        if status != NFCNDEFStatus.notSupported {
                            result["ndefAvailable"] = true
                        }
                        if status == NFCNDEFStatus.readWrite {
                            result["ndefWritable"] = true
                            result["ndefCanMakeReadOnly"] = true
                        }
                        result["ndefCapacity"] = capacity
                    }
                    // ignore error, just return with ndef disabled
                    switch self.tag {
                    case let .feliCa(tag):
                        tag.polling(systemCode: tag.currentSystemCode, requestCode: .noRequest, timeSlot: .max16) { (pmm: Data, _: Data, error: Error?) in
                            dispatchPrecondition(condition: .onQueue(.main))
                            guard self.session === session,
                                  self.activeOperationID == operationID,
                                  !self.invalidationRequested else {
                                return
                            }
                            if let error = error {
                                self.pendingPoll.take(operationID: operationID)?(
                                    FlutterError(code: "500", message: "Communication error on connect", details: error.localizedDescription)
                                )
                            } else {
                                result["manufacturer"] = pmm.hexEncodedString()

                                let jsonData = try! JSONSerialization.data(withJSONObject: result)
                                let jsonString = String(data: jsonData, encoding: .utf8)
                                self.pendingPoll.take(operationID: operationID)?(jsonString)
                            }
                        }
                    default:
                        let jsonData = try! JSONSerialization.data(withJSONObject: result)
                        let jsonString = String(data: jsonData, encoding: .utf8)
                        self.pendingPoll.take(operationID: operationID)?(jsonString)
                    }
                }
            } else {
                let jsonData = try! JSONSerialization.data(withJSONObject: result)
                let jsonString = String(data: jsonData, encoding: .utf8)
                self.pendingPoll.take(operationID: operationID)?(jsonString)
            }
        }
    }
}
