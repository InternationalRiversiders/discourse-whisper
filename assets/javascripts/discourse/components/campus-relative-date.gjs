import Component from "@glimmer/component";
import dAgeWithTooltip from "discourse/ui-kit/helpers/d-age-with-tooltip";
import { asDate, formatDateTime } from "../lib/campus-time";
const relative = (value) => dAgeWithTooltip(asDate(value), { title: false });
export default class extends Component {
  get title() { return formatDateTime(this.args.date); }
  get iso() { return asDate(this.args.date)?.toISOString(); }
  <template><time datetime={{this.iso}} title={{this.title}}>{{relative @date}}</time></template>
}
