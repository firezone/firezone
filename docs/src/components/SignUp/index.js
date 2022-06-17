import React, { useState } from "react";
import styles from "./styles.module.css";

const SignUp = () => {
  const [email, setEmail] = useState("");
  const [isInvalid, setIsInvalid] = useState("");

  const onSubmit = () => {
    if (email.length > 1) {
      console.log(email);
    }
  };
  return (
    <div className={styles.signupWrapper}>
      <iframe
        height="100%"
        width="100%"
        src="https://cdn.forms-content.sg-form.com/ae95a755-f1b0-11ec-bae1-cec19e074e52"
      />
    </div>
  );
};

export default SignUp;
