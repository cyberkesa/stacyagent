let manager = AccountManager(name: "Ada")

// BUG: must return the number of users (1), never a negative count.
func userCount() -> Int {
    return -1
}

func managerName() -> String {
    manager.name
}
