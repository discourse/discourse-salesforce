import discourseComputed from "discourse-common/utils/decorators";
import TopicListItem from "discourse/components/topic-list-item";

export default {
  name: "salesforce-topic-list-class",
  initialize() {
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
  },
};
