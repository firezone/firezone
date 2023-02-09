import React from "react";
import styles from "./styles.module.css";

const AccentBlock = ({
  title,
  description,
  buttonOneText,
  buttonOneLink,
  buttonTwoText,
  buttonTwoLink,
  imageSrc,
  imageAlt,
  imageHeight,
}) => {
  return (
    <div className={styles.accentBlock}>
      <div className={styles.contentBlock}>
        <div>
          <h1>{title ? title : "Please Add Title"}</h1>
          <p>{description ? description : "Please Add Description"}</p>
        </div>
        <div className={styles.btnWrapper}>
          {buttonOneText && buttonOneLink && (
            <button
              onClick={() => window.open(buttonOneLink)}
              className={styles.btnPrimary}>
              {buttonOneText}
            </button>
          )}
          {buttonTwoText && buttonTwoLink && (
            <button
              onClick={() => window.open(buttonTwoLink)}
              className={styles.btn}>
              {buttonTwoText}
            </button>
          )}
        </div>
      </div>
      {imageSrc && (
        <img
          alt={imageAlt}
          src={imageSrc}
          height={imageHeight}
          className={styles.sideImage}></img>
      )}
    </div>
  );
};

export default AccentBlock;
