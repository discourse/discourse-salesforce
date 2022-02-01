import discourseComputed from "discourse-common/utils/decorators";

function initializeWithApi(api) {
  api.modifyClass("component:topic-list-item", {
    @discourseComputed()
    unboundClassNames() {
      let classList = this._super(...arguments);
      if (this.topic.has_accepted_answer) {
        classList += " salesforce-case";
      }
      return classList;
    },
  });
}

export default {
  name: "salesforce-topic-list-class",
  initialize() {
    withPluginApi("0.1", initializeWithApi);
  },
};
