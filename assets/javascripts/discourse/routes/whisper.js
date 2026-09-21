import DiscourseRoute from "discourse/routes/discourse";
import { ajax } from "discourse/lib/ajax";

export default class extends DiscourseRoute {
  model(_params, transition) {
    // During a sidebar transition, window.location still belongs to the previous app.
    const query = new URLSearchParams(transition.to.queryParams).toString();
    return ajax("/whisper/state.json" + (query ? "?" + query : ""));
  }
}
