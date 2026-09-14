func describe(_ m: AccountManager) -> String {
    m.active ? "active user \(m.name)" : "inactive user \(m.name)"
}

let summary = describe(AccountManager(name: "Grace"))
