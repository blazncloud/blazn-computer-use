/// Delivery selection is capability-driven and happens before any mutation.
/// Each tool executes exactly one returned route.

enum ClickDeliveryRoute: Equatable {
    case axPress
    case synthetic
}

func clickDeliveryRoute(hasPressableElement: Bool) -> ClickDeliveryRoute {
    hasPressableElement ? .axPress : .synthetic
}

/// Execute exactly the route selected from preflight capabilities. Keeping the
/// branch and dispatch together prevents a handler from accidentally running
/// both delivery closures.
func deliverSelectedClick<Result>(
    hasPressableElement: Bool,
    axPress: () async throws -> Result,
    synthetic: () async throws -> Result
) async rethrows -> Result {
    switch clickDeliveryRoute(hasPressableElement: hasPressableElement) {
    case .axPress: return try await axPress()
    case .synthetic: return try await synthetic()
    }
}

enum TextDeliveryRoute: Equatable {
    case selectedText
    case valueSplice
    case synthetic
}

func textDeliveryRoute(
    selectedTextSettable: Bool, valueSettable: Bool
) -> TextDeliveryRoute {
    if selectedTextSettable { return .selectedText }
    if valueSettable { return .valueSplice }
    return .synthetic
}
