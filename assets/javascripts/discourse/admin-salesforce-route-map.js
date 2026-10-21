export default {
  resource: "admin.adminPlugins.show",
  path: "/plugins",

  map() {
    this.route("salesforce-guided-sync", { path: "guided-sync" });
  },
};
