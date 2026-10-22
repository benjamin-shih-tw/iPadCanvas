import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var isHoveringWindow: Bool = true
    @State private var showOpacityPopover: Bool = false
    @State private var showSettingsPopover: Bool = false
    @State private var hoverHideTask: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08)
                .ignoresSafeArea()

            // Live hardware-accelerated video surface
            VideoSurfaceRepresentable(
                canvasView: state.canvasView,
                rotationDegrees: state.rotationDegrees,
                isFlippedHorizontally: state.isFlippedHorizontally,
                videoSize: state.videoSize
            )
            .ignoresSafeArea()
            .opacity(state.isStreaming ? 1.0 : 0.0)

            // Onboarding / Waiting Guide when no stream is active
            if !state.isStreaming {
                WaitingGuideView(state: state)
                    .transition(.opacity)
            }

            // Top Floating Glass HUD Bar
            VStack(spacing: 0) {
                FloatingHUDBar(
                    state: state,
                    showOpacityPopover: $showOpacityPopover,
                    showSettingsPopover: $showSettingsPopover
                )
                .padding(.top, state.isBorderless ? 10 : 28)
                .padding(.horizontal, 14)
                .opacity((!state.isStreaming || isHoveringWindow || showOpacityPopover || showSettingsPopover) ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.18), value: isHoveringWindow)

                Spacer()

                // Toast Notification Banner
                if let toast = state.toastMessage {
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.78))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                )
                        )
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Borderless Subtle Frame Indicator on Hover
            if state.isBorderless && isHoveringWindow {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1.5)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hoverHideTask?.cancel()
                if !isHoveringWindow {
                    isHoveringWindow = true
                }
                if state.isStreaming {
                    let task = DispatchWorkItem {
                        if !showOpacityPopover && !showSettingsPopover {
                            isHoveringWindow = false
                        }
                    }
                    hoverHideTask = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: task)
                }
            case .ended:
                hoverHideTask?.cancel()
                if !showOpacityPopover && !showSettingsPopover {
                    isHoveringWindow = false
                }
            }
        }
    }
}

// MARK: - Floating Glass HUD Bar

private struct FloatingHUDBar: View {
    @ObservedObject var state: AppState
    @Binding var showOpacityPopover: Bool
    @Binding var showSettingsPopover: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Connection Status Pill
            HStack(spacing: 6) {
                Circle()
                    .fill(state.isStreaming ? Color.green : (state.isServerRunning ? Color.orange : Color.red))
                    .frame(width: 8, height: 8)

                Text(state.isStreaming ? state.connectedDeviceName : state.serverName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if state.isStreaming {
                    Text("\(Int(state.videoSize.width))×\(Int(state.videoSize.height)) · \(max(state.currentFPS, 1))fps")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.68))

                    if state.connectionMode == .wifiAirPlay && state.currentLatencyMs > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9))
                                .foregroundColor(state.currentLatencyMs < 20 ? .green : (state.currentLatencyMs < 40 ? .yellow : .orange))
                            Text(String(format: "%.0f ms", state.currentLatencyMs))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(state.currentLatencyMs < 20 ? .green : (state.currentLatencyMs < 40 ? .yellow : .orange))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .help("目前 Wi-Fi 實時無線傳輸延遲（越低越逼近有線）")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.08)))

            Spacer(minLength: 4)

            // Mode Quick Switch
            Picker("", selection: $state.connectionMode) {
                Text("Wi-Fi 無線").tag(ConnectionMode.wifiAirPlay)
                Text("USB 有線").tag(ConnectionMode.usbCable)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .help("切換 Wi-Fi AirPlay 視窗鏡像或 USB 有線擷取")

            Divider()
                .frame(height: 18)
                .background(Color.white.opacity(0.2))

            // Always on Top Button
            HUDIconButton(
                icon: state.isAlwaysOnTop ? "pin.fill" : "pin",
                label: "置頂",
                isActive: state.isAlwaysOnTop,
                tooltip: "視窗置頂 Always on Top (⌘T)\n開啟時固定在最上層；關閉時可用 ⌘Tab 一般切換"
            ) {
                state.toggleAlwaysOnTop()
            }

            // Borderless Mode Button
            HUDIconButton(
                icon: state.isBorderless ? "rectangle.inset.filled" : "macwindow",
                label: "無邊框",
                isActive: state.isBorderless,
                tooltip: "切換無邊框純淨畫布模式 (⌘B)\n隱藏系統標題列，按住畫面任意處可直接拖曳視窗"
            ) {
                state.toggleBorderless()
            }

            // Artist Horizontal Flip Button
            HUDIconButton(
                icon: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill",
                label: "水平翻轉",
                isActive: state.isFlippedHorizontally,
                tooltip: "水平鏡像翻轉畫布 (⌘F)\n畫圖時即時檢查骨架與左右構圖平衡"
            ) {
                state.toggleHorizontalFlip()
            }

            // Rotate 90° Button
            HUDIconButton(
                icon: "rotate.right",
                label: "旋轉",
                isActive: state.rotationDegrees != 0,
                tooltip: "順時針旋轉 90° (⌘R)"
            ) {
                state.rotateClockwise()
            }

            // Fit Aspect Ratio Button
            HUDIconButton(
                icon: "aspectratio",
                label: "貼合比例",
                isActive: false,
                tooltip: "消除黑邊，使視窗貼合 iPad 畫布長寬比 (⌘0)"
            ) {
                state.fitWindowToVideoAspect()
            }

            // Opacity & Click-Through Tracing Popover
            HUDIconButton(
                icon: state.isClickThrough ? "eye.trianglebadge.exclamationmark.fill" : "slider.horizontal.below.rectangle",
                label: state.windowOpacity < 0.99 ? "\(Int(state.windowOpacity * 100))%" : "描圖/透明",
                isActive: state.windowOpacity < 0.99 || state.isClickThrough,
                tooltip: "調整視窗透明度與滑鼠穿透描圖模式"
            ) {
                showOpacityPopover.toggle()
            }
            .popover(isPresented: $showOpacityPopover, arrowEdge: .bottom) {
                OpacityTracingPopover(state: state)
            }

            // Screenshot Copy & Save
            if state.isStreaming {
                HUDIconButton(
                    icon: "doc.on.clipboard",
                    label: "複製",
                    isActive: false,
                    tooltip: "複製當前 iPad 畫面至剪貼簿 (⌘C)"
                ) {
                    state.copyScreenshotToClipboard()
                }

                HUDIconButton(
                    icon: "camera.fill",
                    label: "截圖",
                    isActive: false,
                    tooltip: "儲存高畫質 PNG 截圖至桌面 (⌘S)"
                ) {
                    state.saveScreenshotToDesktop()
                }
            }

            // Settings Popover
            HUDIconButton(
                icon: "gearshape.fill",
                label: nil,
                isActive: showSettingsPopover,
                tooltip: "鏡像畫質與連線設定"
            ) {
                showSettingsPopover.toggle()
            }
            .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                SettingsPopoverView(state: state)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

private struct HUDIconButton: View {
    let icon: String
    let label: String?
    let isActive: Bool
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                if let label = label {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundColor(isActive ? Color.white : Color.white.opacity(0.85))
            .padding(.horizontal, label != nil ? 8 : 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isActive ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

// MARK: - Popovers

private struct OpacityTracingPopover: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("半透明對照與描圖穿透")
                .font(.system(size: 13, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("視窗透明度")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(Int(state.windowOpacity * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: $state.windowOpacity, in: 0.2...1.0, step: 0.05)
            }

            Divider()

            Toggle(isOn: $state.isClickThrough) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("滑鼠點擊穿透 (Click-Through)")
                        .font(.system(size: 12, weight: .medium))
                    Text("開啟後滑鼠可直接操作下方的 Mac 參考圖視窗。\n按全局快捷鍵 ⌥Space 或從右上角選單列可隨時關閉。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

private struct SettingsPopoverView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iPad 畫布視窗設定")
                .font(.system(size: 13, weight: .bold))

            if state.connectionMode == .wifiAirPlay {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AirPlay 接收器名稱（顯示於 iPad 螢幕鏡像列表）")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("iPad 畫布視窗", text: $state.serverName)
                            .textFieldStyle(.roundedBorder)
                        Button("套用") {
                            state.restartAirPlayServer()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("無線串流解析度與幀率")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Picker("", selection: $state.qualityPreset) {
                        ForEach(AirPlayQualityPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .labelsHidden()
                }

                Toggle("啟用 Apple 點對點直連 (AWDL P2P)", isOn: $state.enableP2P)
                    .font(.system(size: 12))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("USB 視訊裝置")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if state.usbDevices.isEmpty {
                        Text("尚未偵測到 USB 連接的 iPad")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    } else {
                        Picker("裝置", selection: $state.selectedUSBDeviceID) {
                            Text("自動選擇 iPad").tag("")
                            ForEach(state.usbDevices) { dev in
                                Text(dev.name).tag(dev.id)
                            }
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("常用快捷鍵")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("• ⌥Space：全局快速顯示 / 隱藏視窗")
                Text("• ⌘T：切換視窗置頂   • ⌘B：切換無邊框模式")
                Text("• ⌘F：水平鏡像翻轉   • ⌘R：旋轉畫布 90°")
                Text("• ⌘0：自動貼合畫布比例消除黑邊")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            HStack {
                if state.isStreaming {
                    Button("中斷目前 iPad 連線") {
                        state.disconnectCurrentClient()
                    }
                }
                Spacer()
                Button("重新整理服務") {
                    if state.connectionMode == .wifiAirPlay {
                        state.restartAirPlayServer()
                    } else {
                        state.start()
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - Waiting / Onboarding Guide View

private struct WaitingGuideView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 22) {
            // Header Icon & Title
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.28), Color.purple.opacity(0.22)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 72, height: 72)

                    Image(systemName: state.connectionMode == .wifiAirPlay ? "ipad.and.iphone" : "cable.connector.horizontal")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(.white)
                }

                Text("iPad 畫布視窗 (Windowed Mirror)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                Text("在 iPad 上用 Procreate / GoodNotes 繪圖，同時在 Mac 視窗即時顯示、自由切換不強制全螢幕")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
            }

            if state.connectionMode == .wifiAirPlay {
                // Wi-Fi AirPlay Instructions Card
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(state.isServerRunning ? Color.green : Color.red)
                                .frame(width: 10, height: 10)
                            Text(state.isServerRunning ? "Wi-Fi 視窗化 AirPlay 接收器已就緒" : "接收器尚未啟動")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        Text("名稱：\(state.serverName)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.cyan.opacity(0.15)))
                    }

                    Divider().background(Color.white.opacity(0.12))

                    GuideStepRow(
                        number: "1",
                        title: "從 iPad 右上角下滑打開「控制中心」",
                        subtitle: "確認 iPad 與 Mac 連接至同一個 Wi-Fi 網路（或開啟 Wi-Fi / 藍牙）"
                    )

                    GuideStepRow(
                        number: "2",
                        title: "點選「螢幕鏡像輸出 (Screen Mirroring)」",
                        subtitle: "圖示為兩個重疊的長方形視窗"
                    )

                    GuideStepRow(
                        number: "3",
                        title: "選擇「\(state.serverName)」即可在視窗中顯示！",
                        subtitle: "⚠️ 請選「\(state.serverName)」（不要選 Mac 本機名稱），畫面就會直接顯示在此視窗中，絕不會被系統強制全螢幕！"
                    )

                    HStack(spacing: 12) {
                        Picker("傳輸模式", selection: $state.qualityPreset) {
                            ForEach(AirPlayQualityPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .frame(maxWidth: 420)

                        Spacer()

                        Button {
                            state.restartAirPlayServer()
                        } label: {
                            Label("重新廣播訊號", systemImage: "arrow.clockwise")
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(22)
                .frame(maxWidth: 560)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                )
            } else {
                // USB Cable Instructions Card
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .foregroundColor(.yellow)
                        Text("USB 有線零延遲直連模式")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Button {
                            state.start()
                        } label: {
                            Label("重新掃描 USB", systemImage: "arrow.clockwise")
                        }
                    }

                    Divider().background(Color.white.opacity(0.12))

                    GuideStepRow(
                        number: "1",
                        title: "使用 USB-C / Lightning 傳輸線連接 iPad 與 Mac",
                        subtitle: "若 iPad 跳出「要信任這部電腦嗎？」，請點擊「信任」並輸入密碼"
                    )

                    GuideStepRow(
                        number: "2",
                        title: "連接後將自動顯示畫面",
                        subtitle: "目前狀態：\(state.statusMessage)"
                    )
                }
                .padding(22)
                .frame(maxWidth: 560)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                )
            }

            // Feature Highlights Footer
            HStack(spacing: 18) {
                FeatureBadge(icon: "pin.fill", text: "⌘T 視窗置頂釘選")
                FeatureBadge(icon: "rectangle.inset.filled", text: "⌘B 無邊框純淨畫布")
                FeatureBadge(icon: "arrow.left.and.right", text: "⌘F 水平翻轉檢查骨架")
                FeatureBadge(icon: "command", text: "⌥Space 全局秒切視窗")
            }
            .padding(.top, 4)
        }
        .padding(32)
        .padding(.top, 36)
    }
}

private struct GuideStepRow: View {
    let number: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FeatureBadge: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}
