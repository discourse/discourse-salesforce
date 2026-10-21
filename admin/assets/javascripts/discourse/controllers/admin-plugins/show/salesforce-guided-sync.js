import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";
import { action } from "@ember/object";

export default class SalesforceGuidedSyncController extends Controller {
  @tracked configuration = null;

  queryParams = ["configuration"];

  @action
  selectConfiguration(id) {
    this.configuration = id;
  }

  @action
  clearConfiguration() {
    this.configuration = null;
  }
}
