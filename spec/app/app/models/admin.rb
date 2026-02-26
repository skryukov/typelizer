class Admin < AbstractBase
  self.table_name = "users"

  enum role: {guest: 0, member: 1, admin: 2, superadmin: 3}
end
