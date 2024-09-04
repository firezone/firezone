"use client";
import { useState } from "react";

export default function Pills({
  options,
  multiselect,
}: {
  options: Array<string>;
  multiselect: boolean;
}) {
  const [filters, setFilters] = useState("All Posts");

  return (
    <div className="flex flex-wrap justify-center md:justify-start md:flex-row gap-3">
      {options.map((option, index) => (
        <button
          key={index}
          className={`flex px-8 py-4 rounded-full leading-3 border-[1px] hover:brightness-95 ${
            filters == option
              ? "bg-primary-100 text-primary-450 border-primary-450 font-semibold"
              : "bg-white border-neutral-400"
          }`}
          onClick={() => setFilters(option)}
        >
          {option}
        </button>
      ))}
    </div>
  );
}
