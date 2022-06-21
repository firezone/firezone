import React, { useState } from "react";
import styles from "./styles.module.css";

const Feedback = () => {
  const [showFeedbackAction, setShowFeedbackAction] = useState(false);
  return (
    <div className={styles.feedbackWrapper}>
      <h1>
        {showFeedbackAction
          ? "Thanks for the feedback"
          : "Was this page useful?"}
      </h1>
      {!showFeedbackAction ? (
        <div className={styles.voteWrapper}>
          <button onClick={() => setShowFeedbackAction(true)}>
            <img src="img/like.svg"></img> Like
          </button>
          <button onClick={() => setShowFeedbackAction(true)}>
            <img src="img/dislike.svg"></img> Dislike
          </button>
        </div>
      ) : (
        <div>
          <p>
            If you need help on any of the above, feel free to create an issue
            on <a href="">our repo</a>, or <a href="">join our Slack</a> where a
            member of our team can assist you! Chances are that if you have a
            problem or question, someone else does too - so please don't
            hesitate to create a new issue or ask us a question.
          </p>
        </div>
      )}
    </div>
  );
};

export default Feedback;
