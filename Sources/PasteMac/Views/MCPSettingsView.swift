import SwiftUI
import AppKit
import PasteCore

struct MCPSettingsView: View {
    @ObservedObject var service: MCPService
    @State private var read = true
    @State private var write = false
    @State private var copy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("允许本机 MCP 客户端连接", isOn: Binding(get: { service.enabled }, set: { $0 ? service.start() : service.stop() }))
            Text("首次连接须经批准。客户端名称由客户端提供，不代表其身份。历史记录可能包含敏感信息。")
                .font(.caption).foregroundStyle(.secondary)
            if let status = service.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            if service.enabled {
                Button("复制客户端配置") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(service.clientConfiguration, forType: .string) }
                Text("将配置添加至 MCP 客户端后，在此批准连接。连接期间需保持 Pasteboard 运行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !service.pending.isEmpty {
                Divider(); Text("待批准的连接").font(.headline)
                HStack {
                    Toggle("读取历史", isOn: $read)
                    Toggle("新增文本", isOn: $write)
                    Toggle("写入剪贴板", isOn: $copy)
                }.toggleStyle(.checkbox)
                ForEach(service.pending) { request in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(request.name).lineLimit(1)
                            Text("申请编号 \(request.id.prefix(8)) · 3 分钟内有效").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("拒绝") { service.deny(request.id) }
                        Button("允许所选权限") {
                            var permissions: Set<MCPPermission> = []
                            if read { permissions.insert(.read) }; if write { permissions.insert(.write) }; if copy { permissions.insert(.copy) }
                            service.approve(request.id, permissions: permissions.intersection(request.requested))
                        }.disabled(!read && !write && !copy)
                    }
                }
            }
            if !service.clients.isEmpty {
                Divider(); Text("已授权的客户端").font(.headline)
                ForEach(service.clients) { client in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(client.name)
                            Text(service.isActive(client.id) ? "本次运行已启用" : "已停用").font(.caption).foregroundStyle(.secondary)
                            Text(client.permissions.map { permission in
                                switch permission { case .read: return "读取历史"; case .write: return "新增文本"; case .copy: return "写入剪贴板" }
                            }.sorted().joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !service.isActive(client.id) {
                            Button("启用") { service.resume(client.id) }.disabled(!service.enabled)
                        }
                        Button("撤销授权") { service.revoke(client.id) }
                    }
                }
            }
            Text("复制仅写入系统剪贴板。关闭服务将断开连接；重新开启服务或重启应用后，需手动启用已授权客户端。客户端授权不包含在历史备份中。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }
}
