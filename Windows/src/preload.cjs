const { contextBridge, ipcRenderer } = require("electron");
contextBridge.exposeInMainWorld("naigrey", {
  bootstrap: () => ipcRenderer.invoke("bootstrap"),
  command: (name, value) => ipcRenderer.invoke("command", name, value),
  on: (type, callback) => {
    if (!["state", "action", "bubble"].includes(type)) return;
    ipcRenderer.on(type, (_event, value) => callback(value));
  },
});
