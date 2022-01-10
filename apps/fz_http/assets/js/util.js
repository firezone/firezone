import moment from "moment"

const FormatTimestamp = function (timestamp) {
  if (timestamp) {
    return moment(timestamp).format("llll z")
  } else {
    return "Never"
  }
}

export { FormatTimestamp }
