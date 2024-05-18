"use client";
import { useState, useEffect } from "react";
import { motion, AnimatePresence } from "framer-motion";

export function SlideIn({
  children,
  direction,
  fromOffScreen,
  duration = 0.5,
  delay = 0,
  className = "",
}: {
  children: React.ReactNode;
  direction: "left" | "right" | "top" | "bottom";
  fromOffScreen?: boolean;
  duration?: number;
  delay?: number;
  className?: string;
}) {
  const amount = fromOffScreen ? 500 : 25;
  const initialX =
    direction === "left" ? amount : direction === "right" ? -amount : 0;
  const initialY =
    direction === "top" ? amount : direction === "bottom" ? -amount : 0;
  return (
    <motion.div
      initial={{
        opacity: 0,
        x: initialX,
        y: initialY,
      }}
      whileInView={{
        opacity: 1,
        x: 0,
        y: 0,
      }}
      transition={{ delay, duration, type: "spring" }}
      viewport={{ once: true }}
      className={className}
    >
      {children}
    </motion.div>
  );
}

export function RotatingWords({
  words,
  className = "",
}: {
  words: string[];
  className?: string;
}) {
  const [index, setIndex] = useState(0);

  useEffect(() => {
    const interval = setInterval(() => {
      setIndex((prevIndex) => (prevIndex + 1) % words.length);
    }, 2000); // Change word every second

    return () => clearInterval(interval);
  }, [words.length]);

  return (
    <AnimatePresence mode="wait">
      <motion.span
        className={className}
        key={words[index]}
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        exit={{ opacity: 0, y: -20 }}
        transition={{ duration: 0.2 }}
      >
        {words[index]}
      </motion.span>
    </AnimatePresence>
  );
}

export function Strike({
  delay = 0.5,
  duration = 0.5,
  children,
}: {
  delay?: number;
  duration?: number;
  children: React.ReactNode;
}) {
  return (
    <span className="relative">
      {children}
      <motion.span
        className="h-1 left-0 top-1/2 absolute bg-primary-450 -translate-y-1/2"
        initial={{ width: 0 }}
        whileInView={{ width: "100%" }}
        viewport={{ once: true }}
        transition={{ delay, duration, type: "tween" }}
      />
    </span>
  );
}
