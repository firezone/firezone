import moment from "moment"

const FormatTimestamp = function (timestamp) {
  if (timestamp) {
    return moment(timestamp).format("dddd, MMMM Do YYYY, h:mm:ss a z")
  } else {
    return "Never"
  }
}

export { FormatTimestamp }
