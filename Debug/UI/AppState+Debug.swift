#if DEBUG
import Foundation

extension AppState {
    func resetStrictModeForDebug() {
        SharedStore.resetStrictModeForDebug()
        reload()
    }

    func resetTipsDisplayForDebug() {
        SharedStore.resetTipsDisplayForDebug()
        reload()
    }

}
#endif
