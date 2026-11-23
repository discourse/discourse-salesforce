export default {
  resource: "admin.adminPlugins.show",
  path: "/plugins",

  map() {
    this.route("salesforce-activity", { path: "activity" });
    this.route("salesforce-configurations", { path: "configurations" });
  },
};
