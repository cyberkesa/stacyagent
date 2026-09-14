struct AccountManager {
    var name: String
    var active: Bool = true
}

let marker = "TODO: document AccountManager lifecycle"

func primaryUser() -> AccountManager {
    AccountManager(name: "Ada")
}
