//
//  AlibabaTranslationService.swift
//  OmniKit
//
//  Created by lincunhao on 2026/4/14.
//

import Foundation
import CryptoKit

struct AlibabaTranslationService {
    private let endpoint = URL(string: "https://mt.cn-hangzhou.aliyuncs.com/")!

    func translate(
        text: String,
        accessKeyId: String,
        accessKeySecret: String,
        sourceLanguage: String = "auto",
        targetLanguage: String = "zh",
        apiVersion: String = "2018-10-12",
        formatType: String = "text"
    ) async throws -> String {
        let trimmedId = accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = accessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !trimmedSecret.isEmpty else {
            throw TranslationError.missingCredentials
        }

        var params: [String: String] = [
            "Action": "TranslateGeneral",
            "Format": "JSON",
            "Version": apiVersion,
            "AccessKeyId": trimmedId,
            "SignatureMethod": "HMAC-SHA1",
            "Timestamp": iso8601Timestamp(),
            "SignatureVersion": "1.0",
            "SignatureNonce": UUID().uuidString,
            "RegionId": "cn-hangzhou",
            "SourceLanguage": sourceLanguage,
            "TargetLanguage": targetLanguage,
            "SourceText": text,
            "FormatType": formatType,
            "SourceTextType": formatType,
            "Scene": "general"
        ]
        let signature = sign(parameters: params, accessKeySecret: trimmedSecret)
        params["Signature"] = signature

        let body = params
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "未知错误"
            throw TranslationError.serverError(message)
        }

        let translatedText = try parseTranslatedText(from: data)
        guard !translatedText.isEmpty else {
            throw TranslationError.emptyResult
        }
        return translatedText
    }

    func translateToChinese(
        text: String,
        accessKeyId: String,
        accessKeySecret: String,
        apiVersion: String = "2018-10-12",
        formatType: String = "text"
    ) async throws -> String {
        try await translate(
            text: text,
            accessKeyId: accessKeyId,
            accessKeySecret: accessKeySecret,
            sourceLanguage: "auto",
            targetLanguage: "zh",
            apiVersion: apiVersion,
            formatType: formatType
        )
    }

    private func parseTranslatedText(from data: Data) throws -> String {
        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.invalidResponse
        }

        if let code = jsonObject["Code"] as? String, code != "200" {
            let message = (jsonObject["Message"] as? String) ?? "未知错误"
            throw TranslationError.serverError("\(code): \(message)")
        }

        guard let dataObject = jsonObject["Data"] as? [String: Any],
              let translated = dataObject["Translated"] as? String else {
            throw TranslationError.invalidResponse
        }
        return translated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sign(parameters: [String: String], accessKeySecret: String) -> String {
        let canonicalizedQuery = parameters
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")

        let stringToSign = "POST&%2F&\(percentEncode(canonicalizedQuery))"
        let key = SymmetricKey(data: Data("\(accessKeySecret)&".utf8))
        let signature = HMAC<Insecure.SHA1>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        return Data(signature).base64EncodedString()
    }

    private func iso8601Timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum TranslationError: LocalizedError {
    case missingCredentials
    case invalidResponse
    case emptyResult
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "请先配置 AccessKey ID 和 AccessKey Secret。"
        case .invalidResponse:
            return "翻译服务响应无效。"
        case .emptyResult:
            return "翻译结果为空。"
        case .serverError(let message):
            return "阿里云服务返回错误：\(message)"
        }
    }
}
