//
//  SettingsFormSizeReader.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(iOS)
  import SwiftUI

  struct SettingsFormSizeReader: UIViewRepresentable {
    @Binding var height: CGFloat?

    func makeUIView(context: Context) -> SizeView {
      let view = SizeView()
      view.isUserInteractionEnabled = false
      return view
    }

    func updateUIView(_ view: SizeView, context: Context) {
      view.onChange = { height = $0 }
      view.scheduleMeasurement()
    }

    final class SizeView: UIView {
      var onChange: ((CGFloat) -> Void)?
      private weak var scrollView: UIScrollView?
      private var observation: NSKeyValueObservation?
      private var keyboardObservers: [NSObjectProtocol] = []
      private var isKeyboardPresented = false
      private var lastHeight: CGFloat?

      override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
          observation = nil
          scrollView = nil
          return
        }
        if keyboardObservers.isEmpty {
          keyboardObservers = [
            NotificationCenter.default.addObserver(
              forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] _ in
              MainActor.assumeIsolated { self?.isKeyboardPresented = true }
            },
            NotificationCenter.default.addObserver(
              forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
              MainActor.assumeIsolated {
                self?.isKeyboardPresented = false
                self?.scheduleMeasurement()
              }
            },
          ]
        }
        scheduleMeasurement()
      }

      isolated deinit {
        for observer in keyboardObservers {
          NotificationCenter.default.removeObserver(observer)
        }
      }

      func scheduleMeasurement() {
        DispatchQueue.main.async { [weak self] in self?.measure() }
      }

      private func measure() {
        guard window != nil, !isKeyboardPresented else { return }
        if scrollView == nil {
          var ancestor = superview
          while let view = ancestor {
            if let scrollView = view as? UIScrollView {
              self.scrollView = scrollView
              observation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.scheduleMeasurement() }
              }
              break
            }
            ancestor = view.superview
          }
        }
        guard let scrollView, scrollView.contentSize.height > 0 else { return }
        var responder: UIResponder? = self
        while let current = responder, !(current is UIViewController) {
          responder = current.next
        }
        var controller = responder as? UIViewController
        while let parent = controller?.parent { controller = parent }
        let chromeHeight = max(
          0, (controller?.view.bounds.height ?? scrollView.bounds.height) - scrollView.bounds.height
        )
        let insets = scrollView.adjustedContentInset
        let height = scrollView.contentSize.height + insets.top + insets.bottom + chromeHeight
        guard height != lastHeight else { return }
        lastHeight = height
        onChange?(height)
      }
    }
  }
#endif
