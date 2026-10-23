#!/usr/bin/env ruby
require 'open3'
root = File.expand_path('..', __dir__)
models = File.read(File.join(root, 'CloudNow/XCloud/XCloudModels.swift'))
error_type = models[models.index('enum XCloudError:')..]
formatter = File.read(File.join(root, 'CloudNow/XCloud/XCloudSignInMessage.swift'))
tests = <<~'SWIFT'
  let cases: [(Error, String)] = [
      (XCloudError.server(401, #"{"XErr":2148916233,"Redirect":"secret"}"#), "doesn’t have an Xbox profile"),
      (XCloudError.server(401, #"{"XErr":"2148916233"}"#), "usual Xbox account"),
      (XCloudError.server(401, "RAW_PRIVATE_RESPONSE"), "Microsoft account"),
      (XCloudError.server(500, "RAW_PRIVATE_RESPONSE"), "little while"),
      (XCloudError.server(429, "RAW_PRIVATE_RESPONSE"), "little while"),
      (XCloudError.invalidResponse("RAW_PRIVATE_RESPONSE"), "Please try again"),
      (XCloudError.authorizationExpired, "new code"),
      (XCloudError.timedOut("RAW_PRIVATE_RESPONSE"), "took too long"),
      (URLError(.notConnectedToInternet), "internet connection"),
      (NSError(domain: "RAW_PRIVATE_RESPONSE", code: 1), "Please try again")
  ]
  for (error, expected) in cases {
      let result = XCloudSignInMessage.message(for: error)
      precondition(result.contains(expected), result)
      precondition(!result.contains("RAW_PRIVATE_RESPONSE") && !result.contains("secret"))
      precondition(!result.contains("2148916233") && !result.contains("{"))
  }
  print("PASS: 10 sign-in cases; no raw payloads or error codes displayed")
SWIFT
output, status = Open3.capture2e('swift', '-', stdin_data: "import Foundation\n#{error_type}\n#{formatter}\n#{tests}")
puts output
exit(status.success? ? 0 : 1)
