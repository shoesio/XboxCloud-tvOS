#!/usr/bin/env ruby
require 'open3'
root = File.expand_path('..', __dir__)
selection = File.read(File.join(root, 'CloudNow/XCloud/XCloudLaunchSelection.swift'))
source = <<~'SWIFT'
  import Foundation
  enum DirectGameConfiguration {
      static let isRecentGamesLauncher = true
      static let urlScheme = "forza6"
  }
SWIFT
tests = <<~'SWIFT'
  await MainActor.run {
      let key = "xcloud.selectedTitleID"
      let previous = UserDefaults.standard.object(forKey: key)
      defer {
          if let previous { UserDefaults.standard.set(previous, forKey: key) }
          else { UserDefaults.standard.removeObject(forKey: key) }
      }
      UserDefaults.standard.removeObject(forKey: key)
      let selection = XCloudLaunchSelection()
      precondition(selection.requestedGameID == nil)
      precondition(selection.open(URL(string: "forza6://play?id=xcloud%3AFORZAHORIZON6")!))
      precondition(selection.requestedGameID == "FORZAHORIZON6")
      precondition(selection.open(URL(string: "forza6://game?id=HALOINFINITE")!))
      precondition(selection.requestedGameID == "HALOINFINITE")
      let relaunched = XCloudLaunchSelection()
      precondition(relaunched.requestedGameID == nil)
      precondition(relaunched.gameIDForActivation(activeGameID: nil, hasCloudSession: false, firstRecentGameID: "FORTNITE") == "FORTNITE")
      precondition(relaunched.gameIDForActivation(activeGameID: "FORZAHORIZON6", hasCloudSession: true, firstRecentGameID: "FORTNITE") == "FORZAHORIZON6")
      precondition(selection.gameIDForActivation(activeGameID: "FORZAHORIZON6", hasCloudSession: true, firstRecentGameID: "FORTNITE") == "HALOINFINITE")
      selection.markRequestHandled()
      precondition(selection.gameIDForActivation(activeGameID: "HALOINFINITE", hasCloudSession: true, firstRecentGameID: "FORTNITE") == "HALOINFINITE")
      precondition(selection.gameIDForActivation(activeGameID: "HALOINFINITE", hasCloudSession: false, firstRecentGameID: "FORTNITE") == "FORTNITE")
      precondition(relaunched.gameIDForActivation(activeGameID: nil, hasCloudSession: false, firstRecentGameID: nil) == nil)
      for invalid in ["cloudnow://play?id=FORTNITE", "forza6://settings?id=FORTNITE", "forza6://play", "forza6://play?id=", "forza6://play?id=..%2FOTHER"] {
          precondition(!selection.open(URL(string: invalid)!))
          precondition(selection.requestedGameID == "HALOINFINITE")
      }
      print("PASS: icon chooses first card, retained sessions resume, explicit cards override, old saved selections and invalid routes cannot override icon policy")
  }
SWIFT
output, status = Open3.capture2e('swift', '-', stdin_data: source + selection + tests)
puts output
exit(status.success? ? 0 : 1)
