import moment from "moment"

const FormatTimestamp = function (timestamp) {
  return moment(timestamp).format("dddd, MMMM Do YYYY, h:mm:ss a z")
}

export { FormatTimestamp }
