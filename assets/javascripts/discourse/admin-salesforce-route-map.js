export default {
  resource: "admin.adminPlugins.show",
  path: "/plugins",

  map() {
    this.route("salesforce-configurations", { path: "configurations" });
  },
};
