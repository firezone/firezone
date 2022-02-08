import moment from "moment"
import zxcvbn from "zxcvbn"

const FormatTimestamp = function (timestamp) {
  if (timestamp) {
    return moment(timestamp).format("llll z")
  } else {
    return "Never"
  }
}

const PasswordStrength = function (password) {
  const result = zxcvbn(password)
  return result.score
}

export { PasswordStrength, FormatTimestamp }
