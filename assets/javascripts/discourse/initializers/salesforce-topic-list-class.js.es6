import discourseComputed from "discourse-common/utils/decorators";
import { withPluginApi } from "discourse/lib/plugin-api";

function initializeWithApi(api) {
  api.modifyClass("component:topic-list-item", {
    pluginId: "discourse-salesforce",

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
    withPluginApi("1.1.0", initializeWithApi);
  },
};
