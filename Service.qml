import QtQuick
import Quickshell

Item {
  property var pluginRegistry: null
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/obilbie.aur-scan"

  Component.onCompleted: Quickshell.execDetached(["bash", pluginDir + "/enable.sh"])
  Component.onDestruction: {
    if (pluginRegistry && pluginRegistry.isEnabled("obilbie.aur-scan"))
      return
    Quickshell.execDetached(["bash", pluginDir + "/disable.sh"])
  }
}
