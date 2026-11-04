import AppKit
import SwiftUI

private struct RingSectorShape: Shape {
    var startAngle: Angle
    var endAngle: Angle
    var innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) * 0.5
        let innerRadius = outerRadius * innerRatio

        var path = Path()
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: endAngle,
            endAngle: startAngle,
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

public struct CircularDPadView: View {
    @Bindable var appState: AppState
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private let outerDiameter: CGFloat = 188
    private let centerDiameter: CGFloat = 78

    public init(appState: AppState, namespace: Namespace.ID) {
        self.appState = appState
        self.namespace = namespace
    }

    private var arrowPrimaryInk: Color {
        colorScheme == .dark ? .white : .black.opacity(0.92)
    }

    private var arrowIdleInk: Color {
        colorScheme == .dark ? .white.opacity(0.88) : .black.opacity(0.76)
    }

    private var activeDirection: RemoteCommand? {
        appState.pressedDirection ?? {
            switch appState.highlightedCommand {
            case .up, .down, .left, .right:
                return appState.highlightedCommand
            default:
                return nil
            }
        }()
    }

    private var isSelectHighlighted: Bool {
        appState.selectPressed || appState.highlightedCommand == .select || appState.highlightedCommand == .selectHold
    }

    private var pressAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    public var body: some View {
        // Apply .glassEffect directly to the D-Pad ZStack (without a GlassEffectContainer
        // that would metaball-union the concentric circles or hoist blur above the arrows).
        let dpadContent = ZStack {
            directionSectorButton(
                command: .up,
                symbol: "chevron.up",
                startAngle: .degrees(-135),
                endAngle: .degrees(-45),
                labelOffset: CGSize(width: 0, height: -68),
                accessibilityLabel: "Up"
            )

            directionSectorButton(
                command: .right,
                symbol: "chevron.right",
                startAngle: .degrees(-45),
                endAngle: .degrees(45),
                labelOffset: CGSize(width: 68, height: 0),
                accessibilityLabel: "Right"
            )

            directionSectorButton(
                command: .down,
                symbol: "chevron.down",
                startAngle: .degrees(45),
                endAngle: .degrees(135),
                labelOffset: CGSize(width: 0, height: 68),
                accessibilityLabel: "Down"
            )

            directionSectorButton(
                command: .left,
                symbol: "chevron.left",
                startAngle: .degrees(135),
                endAngle: .degrees(225),
                labelOffset: CGSize(width: -68, height: 0),
                accessibilityLabel: "Left"
            )

            // Outer ring crisp specular rim
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [.white.opacity(contrast == .increased ? 0.55 : 0.30), .white.opacity(0.10)]
                            : [.black.opacity(contrast == .increased ? 0.40 : 0.18), .black.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
                .allowsHitTesting(false)

            centerSelectButton
        }
        .frame(width: outerDiameter, height: outerDiameter)
        .animation(pressAnimation, value: activeDirection)
        .animation(pressAnimation, value: isSelectHighlighted)

        if reduceTransparency {
            dpadContent
                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
        } else {
            dpadContent
                .glassEffect(.regular, in: Circle())
        }
    }

    private func directionSectorButton(
        command: RemoteCommand,
        symbol: String,
        startAngle: Angle,
        endAngle: Angle,
        labelOffset: CGSize,
        accessibilityLabel: String
    ) -> some View {
        let sector = RingSectorShape(
            startAngle: startAngle,
            endAngle: endAngle,
            innerRatio: (centerDiameter + 4) / outerDiameter
        )
        let isHighlighted = activeDirection == command
        let highlightFill = colorScheme == .dark
            ? Color.white.opacity(isHighlighted ? 0.18 : 0.001)
            : Color.black.opacity(isHighlighted ? 0.11 : 0.001)

        return ZStack {
            sector
                .fill(highlightFill)

            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(isHighlighted ? arrowPrimaryInk : arrowIdleInk)
                .offset(labelOffset)
        }
        .frame(width: outerDiameter, height: outerDiameter)
        .contentShape(sector)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if appState.pressedDirection != command {
                        appState.pressedDirection = command
                    }
                }
                .onEnded { _ in
                    appState.pressedDirection = nil
                    appState.trigger(command)
                }
        )
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Moves focus \(accessibilityLabel.lowercased()) on Apple TV")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            appState.trigger(command)
        }
    }

    private var centerSelectButton: some View {
        let surfaceFill: Color = {
            if reduceTransparency {
                return Color(nsColor: .windowBackgroundColor)
            }
            if colorScheme == .dark {
                return .white.opacity(isSelectHighlighted ? 0.22 : 0.10)
            } else {
                return .white.opacity(isSelectHighlighted ? 0.85 : 0.55)
            }
        }()

        let rimGradient = LinearGradient(
            colors: colorScheme == .dark
                ? [.white.opacity(contrast == .increased ? 0.70 : 0.45), .white.opacity(0.18)]
                : [.black.opacity(contrast == .increased ? 0.45 : 0.24), .black.opacity(0.10)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return ZStack {
            Circle()
                .fill(surfaceFill)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 5, y: 2)

            Circle()
                .strokeBorder(rimGradient, lineWidth: 1.35)

            Circle()
                .fill(colorScheme == .dark ? .white.opacity(isSelectHighlighted ? 0.75 : 0.38) : .black.opacity(isSelectHighlighted ? 0.55 : 0.28))
                .frame(width: 6, height: 6)
        }
        .frame(width: centerDiameter, height: centerDiameter)
        .scaleEffect(isSelectHighlighted && !reduceMotion ? 0.96 : 1.0)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    appState.beginSelectPress()
                }
                .onEnded { _ in
                    appState.endSelectPress()
                }
        )
        .contextMenu {
            Button {
                appState.trigger(.select)
            } label: {
                Label("Select", systemImage: "hand.tap")
            }
            Button {
                appState.trigger(.selectHold)
            } label: {
                Label("Long Press Select", systemImage: "hand.point.up.left.and.text")
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Select")
        .accessibilityHint("Click to select, or press and hold for Siri Remote context menu")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            appState.trigger(.select)
        }
        .accessibilityAction(named: "Long Press") {
            appState.trigger(.selectHold)
        }
    }
}
