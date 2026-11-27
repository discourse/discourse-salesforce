import Component from "@glimmer/component";
import CrmFlair from "./crm-flair";

export default class CrmPostFlair extends Component {
  static shouldRender(args) {
    return !!args.post?.crm_flair;
  }

  <template><CrmFlair @flair={{@post.crm_flair}} /></template>
}
