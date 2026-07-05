import MCP

func healthReportImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    try await healthReportImpl(args) { probeCaptureService in
        await makeHealthReport(prompt: false, probeCaptureService: probeCaptureService)
    }
}

func healthReportImpl(
    _ args: [String: Value],
    makeReport: @escaping @Sendable (_ probeCaptureService: Bool) async -> HealthReport
) async throws -> CallTool.Result {
    let probeCaptureService = args.bool("probe_capture_service") ?? false
    let report = await makeReport(probeCaptureService)
    return try healthReportResult(report)
}

func healthReportResult(_ report: HealthReport) throws -> CallTool.Result {
    let summary =
        report.ready
        ? "Health report is ready: permissions and capture health are available."
        : "Health report completed with degraded health: \(report.recommendedNextAction)"

    let result = try CallTool.Result(
        content: [.text(text: summary, annotations: nil, _meta: nil)],
        structuredContent: report,
        isError: false
    )
    return result.withActionOutcome(.success(summary))
}
