/// Delivery selection is capability-driven and happens before any mutation.
/// Each tool executes exactly one returned route.

enum ClickDeliveryRoute: Equatable {
    case axPress
    case synthetic
}

func clickDeliveryRoute(hasPressableElement: Bool) -> ClickDeliveryRoute {
    hasPressableElement ? .axPress : .synthetic
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
