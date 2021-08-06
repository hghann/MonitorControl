import AVFoundation
import Cocoa
import DDC
import IOKit
import os.log

class ExternalDisplay: Display {
  var brightnessSliderHandler: SliderHandler?
  var volumeSliderHandler: SliderHandler?
  var contrastSliderHandler: SliderHandler?
  var ddc: DDC?
  var arm64ddc: Bool = false
  var arm64avService: IOAVService?

  var isContrastAfterBrightnessMode: Bool = false

  let DDC_HARD_MAX_LIMIT: Int = 100

  private let prefs = UserDefaults.standard

  var hideOsd: Bool {
    get {
      return self.prefs.bool(forKey: "hideOsd-\(self.identifier)")
    }
    set {
      self.prefs.set(newValue, forKey: "hideOsd-\(self.identifier)")
      os_log("Set `hideOsd` to: %{public}@", type: .info, String(newValue))
    }
  }

  var needsLongerDelay: Bool {
    get {
      return self.prefs.object(forKey: "longerDelay-\(self.identifier)") as? Bool ?? false
    }
    set {
      self.prefs.set(newValue, forKey: "longerDelay-\(self.identifier)")
      os_log("Set `needsLongerDisplay` to: %{public}@", type: .info, String(newValue))
    }
  }

  private var audioPlayer: AVAudioPlayer?

  override init(_ identifier: CGDirectDisplayID, name: String, vendorNumber: UInt32?, modelNumber: UInt32?, isVirtual: Bool = false) {
    super.init(identifier, name: name, vendorNumber: vendorNumber, modelNumber: modelNumber)

    if !isVirtual {
      #if !arch(arm64)

        self.ddc = DDC(for: identifier)

      #endif
    } else {
      self.isVirtual = true
    }
  }

  #if !arch(arm64)

    // Scores the likelihood of a display match based on EDID UUID, ProductName and SerialNumber from in ioreg, compared to DisplayCreateInfoDictionary.
    func ioregMatchScore(ioregEdidUUID: String, ioregProductName: String = "", ioregSerialNumber: Int64 = 0) -> Int {
      var matchScore: Int = 0
      if let dictionary = (CoreDisplay_DisplayCreateInfoDictionary(self.identifier))?.takeRetainedValue() as NSDictionary? {
        if let kDisplayYearOfManufacture = dictionary[kDisplayYearOfManufacture] as? Int64, let kDisplayWeekOfManufacture = dictionary[kDisplayWeekOfManufacture] as? Int64, let kDisplayVendorID = dictionary[kDisplayVendorID] as? Int64, let kDisplayProductID = dictionary[kDisplayProductID] as? Int64, let kDisplayVerticalImageSize = dictionary[kDisplayVerticalImageSize] as? Int64, let kDisplayHorizontalImageSize = dictionary[kDisplayHorizontalImageSize] as? Int64 {
          struct KeyLoc {
            var key: String
            var loc: Int
          }
          let edidUUIDSearchKeys: [KeyLoc] = [
            // Vendor ID
            KeyLoc(key: String(format: "%04x", UInt16(kDisplayVendorID)).uppercased(), loc: 0),
            // Product ID
            KeyLoc(key: String(format: "%02x", UInt8((UInt16(kDisplayProductID) >> (1 * 8)) & 0xFF)).uppercased()
              + String(format: "%02x", UInt8((UInt16(kDisplayProductID) >> (0 * 8)) & 0xFF)).uppercased(), loc: 4),
            // Manufacture date
            KeyLoc(key: String(format: "%02x", UInt8(kDisplayYearOfManufacture - 1990)).uppercased()
              + String(format: "%02x", UInt8(kDisplayWeekOfManufacture)).uppercased(), loc: 19),
            // Image size
            KeyLoc(key: String(format: "%02x", UInt8(kDisplayHorizontalImageSize / 10)).uppercased()
              + String(format: "%02x", UInt8(kDisplayVerticalImageSize / 10)).uppercased(), loc: 30),
          ]
          for searchKey in edidUUIDSearchKeys where searchKey.key != "0000" && searchKey.key == ioregEdidUUID.prefix(searchKey.loc + 4).suffix(4) {
            matchScore += 1
          }
        }
        if ioregProductName != "", let nameList = dictionary["DisplayProductName"] as? [String: String], let name = nameList["en_US"] ?? nameList.first?.value, name.lowercased() == ioregProductName.lowercased() {
          matchScore += 1
        }
        if ioregSerialNumber != 0, let serial = dictionary[kDisplaySerialNumber] as? Int64, serial == ioregSerialNumber {
          matchScore += 1
        }
      }
      return matchScore
    }

  #endif

  // On some displays, the display's OSD overlaps the macOS OSD,
  // calling the OSD command with 1 seems to hide it.
  func hideDisplayOsd() {
    guard self.hideOsd else {
      return
    }

    for _ in 0 ..< 20 {
      _ = self.writeDDCValues(command: .osd, value: UInt16(1), errorRecoveryWaitTime: 2000)
    }
  }

  func isMuted() -> Bool {
    return self.getValue(for: .audioMuteScreenBlank) == 1
  }

  func toggleMute(fromVolumeSlider: Bool = false) {
    var muteValue: Int
    var volumeOSDValue: Int

    if !self.isMuted() {
      muteValue = 1
      volumeOSDValue = 0
    } else {
      muteValue = 2
      volumeOSDValue = self.getValue(for: .audioSpeakerVolume)

      // The volume that will be set immediately after setting unmute while the old set volume was 0 is unpredictable
      // Hence, just set it to a single filled chiclet
      if volumeOSDValue == 0 {
        volumeOSDValue = self.stepSize(for: .audioSpeakerVolume, isSmallIncrement: false)
        self.saveValue(volumeOSDValue, for: .audioSpeakerVolume)
      }
    }

    let volumeDDCValue = UInt16(volumeOSDValue)

    guard self.writeDDCValues(command: .audioSpeakerVolume, value: volumeDDCValue) == true else {
      return
    }

    if self.supportsMuteCommand() {
      guard self.writeDDCValues(command: .audioMuteScreenBlank, value: UInt16(muteValue)) == true else {
        return
      }
    }

    self.saveValue(muteValue, for: .audioMuteScreenBlank)

    if !fromVolumeSlider {
      self.hideDisplayOsd()
      self.showOsd(command: volumeOSDValue > 0 ? .audioSpeakerVolume : .audioMuteScreenBlank, value: volumeOSDValue, roundChiclet: true)

      if volumeOSDValue > 0 {
        self.playVolumeChangedSound()
      }

      if let slider = self.volumeSliderHandler?.slider {
        slider.intValue = Int32(volumeDDCValue)
      }
    }
  }

  func stepVolume(isUp: Bool, isSmallIncrement: Bool) {
    var muteValue: Int?
    let volumeOSDValue = self.calcNewValue(for: .audioSpeakerVolume, isUp: isUp, isSmallIncrement: isSmallIncrement)
    let volumeDDCValue = UInt16(volumeOSDValue)
    if self.isMuted(), volumeOSDValue > 0 {
      muteValue = 2
    } else if !self.isMuted(), volumeOSDValue == 0 {
      muteValue = 1
    }

    let isAlreadySet = volumeOSDValue == self.getValue(for: .audioSpeakerVolume)

    if !isAlreadySet {
      guard self.writeDDCValues(command: .audioSpeakerVolume, value: volumeDDCValue) == true else {
        return
      }
    }

    if let muteValue = muteValue {
      // If the mute command is supported, set its value accordingly
      if self.supportsMuteCommand() {
        guard self.writeDDCValues(command: .audioMuteScreenBlank, value: UInt16(muteValue)) == true else {
          return
        }
      }
      self.saveValue(muteValue, for: .audioMuteScreenBlank)
    }

    self.hideDisplayOsd()
    self.showOsd(command: .audioSpeakerVolume, value: volumeOSDValue, roundChiclet: !isSmallIncrement)

    if !isAlreadySet {
      self.saveValue(volumeOSDValue, for: .audioSpeakerVolume)

      if volumeOSDValue > 0 {
        self.playVolumeChangedSound()
      }

      if let slider = self.volumeSliderHandler?.slider {
        slider.intValue = Int32(volumeDDCValue)
      }
    }
  }

  override func stepBrightness(isUp: Bool, isSmallIncrement: Bool) {
    let osdValue = Int(self.calcNewValue(for: .brightness, isUp: isUp, isSmallIncrement: isSmallIncrement))
    let isAlreadySet = osdValue == self.getValue(for: .brightness)

    // Set the contrast value according to the brightness, if necessary
    if isAlreadySet, !isUp, !self.isContrastAfterBrightnessMode, self.prefs.bool(forKey: Utils.PrefKeys.lowerContrast.rawValue) {
      self.setRestoreValue(self.getValue(for: .contrast), for: .contrast)
      self.isContrastAfterBrightnessMode = true
    }

    if self.isContrastAfterBrightnessMode {
      var contrastValue = Int(self.calcNewValue(for: .contrast, isUp: isUp, isSmallIncrement: isSmallIncrement))
      if contrastValue >= self.getRestoreValue(for: .contrast) {
        contrastValue = self.getRestoreValue(for: .contrast)
        self.isContrastAfterBrightnessMode = false
      }
      let ddcValue = UInt16(contrastValue)
      guard self.writeDDCValues(command: .contrast, value: ddcValue) == true else {
        return
      }
      self.saveValue(contrastValue, for: .contrast)
      if let slider = contrastSliderHandler?.slider {
        slider.intValue = Int32(contrastValue)
      }
      self.showOsd(command: .brightness, value: self.getValue(for: .brightness), roundChiclet: !isSmallIncrement)
    }
    if !self.isContrastAfterBrightnessMode {
      let ddcValue = UInt16(osdValue)
      if !isAlreadySet {
        guard self.writeDDCValues(command: .brightness, value: ddcValue) == true else {
          return
        }
        if let slider = brightnessSliderHandler?.slider {
          slider.intValue = Int32(ddcValue)
        }
      }
      self.showOsd(command: .brightness, value: osdValue, roundChiclet: !isSmallIncrement)
      self.saveValue(osdValue, for: .brightness)
    }
  }

  #if arch(arm64)

    public func arm64ddcComm(send: inout [UInt8], reply: inout [UInt8], writeSleepTime: UInt32 = 10000, numofWriteCycles: UInt8 = 2, readSleepTime: UInt32 = 10000, numOfRetryAttemps: UInt8 = 3, retrySleepTime: UInt32 = 20000) -> Bool {
      var success: Bool = false

      guard self.arm64avService != nil else {
        return success
      }

      var checkedsend: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
      checkedsend[checkedsend.count - 1] = Utils.checksum(chk: send.count == 1 ? 0x6E : 0x6E ^ 0x51, data: &checkedsend, start: 0, end: checkedsend.count - 2)

      for _ in 1 ... numOfRetryAttemps {
        for _ in 1 ... numofWriteCycles {
          usleep(writeSleepTime)
          if IOAVServiceWriteI2C(self.arm64avService, 0x37, 0x51, &checkedsend, UInt32(checkedsend.count)) == 0 {
            success = true
          }
        }

        if reply.count > 0 {
          usleep(readSleepTime)
          if IOAVServiceReadI2C(self.arm64avService, 0x37, 0x51, &reply, UInt32(reply.count)) == 0 {
            if Utils.checksum(chk: 0x50, data: &reply, start: 0, end: reply.count - 2) == reply[reply.count - 1] {
              success = true
            } else {
              success = false
            }
          }
        }

        if success {
          return success
        }

        usleep(retrySleepTime)
      }

      return success
    }

  #endif

  public func writeDDCValues(command: DDC.Command, value: UInt16, errorRecoveryWaitTime _: UInt32? = nil) -> Bool? {
    #if arch(arm64)

      guard self.arm64ddc else {
        return false
      }

      var send: [UInt8] = [command.rawValue, UInt8(value >> 8), UInt8(value & 255)]
      var reply: [UInt8] = []

      return self.arm64ddcComm(send: &send, reply: &reply)

    #else
      // NOTE: Loop is a hacky workaround that should probably be removed as it wasn't necessary before and makes things choppy.
      // SEE: https://github.com/MonitorControl/MonitorControl/issues/478
      var success = false
      for _ in 1 ... 2 {
        success = self.ddc?.write(command: command, value: value, errorRecoveryWaitTime: 2000) ?? false
      }
      return success

    #endif
  }

  func readDDCValues(for command: DDC.Command, tries: UInt, minReplyDelay delay: UInt64?) -> (current: UInt16, max: UInt16)? {
    var values: (UInt16, UInt16)?

    #if arch(arm64)

      guard self.arm64ddc else {
        return nil
      }

      var send: [UInt8] = [command.rawValue]
      var reply = [UInt8](repeating: 0, count: 11)

      if self.arm64ddcComm(send: &send, reply: &reply) {
        let max = UInt16(reply[6]) * 256 + UInt16(reply[7])
        let current = UInt16(reply[8]) * 256 + UInt16(reply[9])
        values = (current, max)
      } else {
        os_log("DDC read was unsuccessful.", type: .debug)
        values = nil
      }

    #else

      if self.ddc?.supported(minReplyDelay: delay) == true {
        os_log("Display supports DDC.", type: .debug)
      } else {
        os_log("Display does not support DDC.", type: .debug)
      }

      if self.ddc?.enableAppReport() == true {
        os_log("Display supports enabling DDC application report.", type: .debug)
      } else {
        os_log("Display does not support enabling DDC application report.", type: .debug)
      }

      values = self.ddc?.read(command: command, tries: tries, minReplyDelay: delay)

    #endif

    return values
  }

  func calcNewValue(for command: DDC.Command, isUp: Bool, isSmallIncrement: Bool) -> Int {
    let currentValue = self.getValue(for: command)
    let nextValue: Int
    let maxValue = Float(self.getMaxValue(for: command))

    if isSmallIncrement {
      nextValue = currentValue + (isUp ? 1 : -1)
    } else {
      let osdChicletFromValue = OSDUtils.chiclet(fromValue: Float(currentValue), maxValue: maxValue)

      let distance = OSDUtils.getDistance(fromNearestChiclet: osdChicletFromValue)
      // get the next rounded chiclet
      var nextFilledChiclet = isUp ? ceil(osdChicletFromValue) : floor(osdChicletFromValue)

      // Depending on the direction, if the chiclet is above or below a certain threshold, we go to the next whole chiclet
      let distanceThreshold = Float(0.25) // 25% of the distance between the edges of an osd box
      if distance == 0 {
        nextFilledChiclet += isUp ? 1 : -1
      } else if !isUp, distance < distanceThreshold {
        nextFilledChiclet -= 1
      } else if isUp, distance > (1 - distanceThreshold) {
        nextFilledChiclet += 1
      }

      nextValue = Int(round(OSDUtils.value(fromChiclet: nextFilledChiclet, maxValue: maxValue)))

      os_log("next: .value %{public}@/%{public}@, .osd %{public}@/%{public}@", type: .debug, String(nextValue), String(maxValue), String(nextFilledChiclet), String(OSDUtils.chicletCount))
    }
    return max(0, min(self.getMaxValue(for: command), nextValue))
  }

  func getValue(for command: DDC.Command) -> Int {
    return self.prefs.integer(forKey: "\(command.rawValue)-\(self.identifier)")
  }

  func saveValue(_ value: Int, for command: DDC.Command) {
    self.prefs.set(value, forKey: "\(command.rawValue)-\(self.identifier)")
  }

  func saveMaxValue(_ maxValue: Int, for command: DDC.Command) {
    self.prefs.set(maxValue, forKey: "max-\(command.rawValue)-\(self.identifier)")
  }

  func getMaxValue(for command: DDC.Command) -> Int {
    let max = self.prefs.integer(forKey: "max-\(command.rawValue)-\(self.identifier)")
    return min(self.DDC_HARD_MAX_LIMIT, max == 0 ? self.DDC_HARD_MAX_LIMIT : max)
  }

  func getRestoreValue(for command: DDC.Command) -> Int {
    return self.prefs.integer(forKey: "restore-\(command.rawValue)-\(self.identifier)")
  }

  func setRestoreValue(_ value: Int?, for command: DDC.Command) {
    self.prefs.set(value, forKey: "restore-\(command.rawValue)-\(self.identifier)")
  }

  func setPollingMode(_ value: Int) {
    self.prefs.set(String(value), forKey: "pollingMode-\(self.identifier)")
  }

  /*
   Polling Modes:
   0 -> .none     -> 0 tries
   1 -> .minimal  -> 5 tries
   2 -> .normal   -> 10 tries
   3 -> .heavy    -> 100 tries
   4 -> .custom   -> $pollingCount tries
   */
  func getPollingMode() -> Int {
    // Reading as string so we don't get "0" as the default value
    return Int(self.prefs.string(forKey: "pollingMode-\(self.identifier)") ?? "2") ?? 2
  }

  func getPollingCount() -> Int {
    let selectedMode = self.getPollingMode()
    switch selectedMode {
    case 0:
      return PollingMode.none.value
    case 1:
      return PollingMode.minimal.value
    case 2:
      return PollingMode.normal.value
    case 3:
      return PollingMode.heavy.value
    case 4:
      let val = self.prefs.integer(forKey: "pollingCount-\(self.identifier)")
      return PollingMode.custom(value: val).value
    default:
      return 0
    }
  }

  func setPollingCount(_ value: Int) {
    self.prefs.set(value, forKey: "pollingCount-\(self.identifier)")
  }

  private func stepSize(for command: DDC.Command, isSmallIncrement: Bool) -> Int {
    return isSmallIncrement ? 1 : Int(floor(Float(self.getMaxValue(for: command)) / OSDUtils.chicletCount))
  }

  override func showOsd(command: DDC.Command, value: Int, maxValue _: Int = 100, roundChiclet: Bool = false) {
    super.showOsd(command: command, value: value, maxValue: self.getMaxValue(for: command), roundChiclet: roundChiclet)
  }

  private func supportsMuteCommand() -> Bool {
    // Monitors which don't support the mute command - e.g. Dell U3419W - will have a maximum value of 100 for the DDC mute command
    return self.getMaxValue(for: .audioMuteScreenBlank) == 2
  }

  private func playVolumeChangedSound() {
    let soundPath = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
    let soundUrl = URL(fileURLWithPath: soundPath)

    // Check if user has enabled "Play feedback when volume is changed" in Sound Preferences
    guard let preferences = Utils.getSystemPreferences(),
          let hasSoundEnabled = preferences["com.apple.sound.beep.feedback"] as? Int,
          hasSoundEnabled == 1
    else {
      os_log("sound not enabled", type: .info)
      return
    }

    do {
      self.audioPlayer = try AVAudioPlayer(contentsOf: soundUrl)
      self.audioPlayer?.volume = 1
      self.audioPlayer?.prepareToPlay()
      self.audioPlayer?.play()
    } catch {
      os_log("%{public}@", type: .error, error.localizedDescription)
    }
  }
}
