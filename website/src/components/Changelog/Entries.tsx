import React from "react";
import Entry from "./Entry";

function Latest({
  title,
  version,
  date,
  children,
}: {
  title: string;
  version: string;
  date: Date;
  children: React.ReactNode;
}) {
  const options: Intl.DateTimeFormatOptions = {
    timeZone: "UTC",
    year: "numeric",
    month: "long",
    day: "numeric",
  };
  const utcDateString = date.toLocaleDateString("en-US", options);
  return (
    <>
      <h3 className="text-lg md:text-xl xl:text-2xl font-semibold tracking-tight mb-4 md:mb-6 xl:mb-8  text-neutral-800">
        Latest {title} version
      </h3>
      <div className="text-sm md:text-lg text-neutral-800 mb-8 md:mb-10 xl:mb-12">
        <p>
          Version: <span className="font-semibold">{version}</span>
        </p>
        <p className="mb-4 md:mb-6 xl:mb-8">
          Released:{" "}
          <span className="font-semibold">
            <time dateTime={date.toDateString()}>{utcDateString}</time>
          </span>
        </p>
        {children}
      </div>
    </>
  );
}

function Previous({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <>
      <h3 className="text-lg md:text-xl xl:text-2xl font-semibold tracking-tight mb-4 md:mb-6 xl:mb-8 text-neutral-800">
        Previous {title} versions
      </h3>
      <table className="w-full text-left">
        <thead className="text-neutral-800 bg-neutral-100 uppercase">
          <tr>
            <th
              scope="col"
              className="px-2 py-1 sm:px-3 sm:py-1.5 md:px-4 md:py-2 lg:px-6 lg:py-3"
            >
              Version
            </th>
            <th
              scope="col"
              className="px-2 py-1 sm:px-3 sm:py-1.5 md:px-4 md:py-2 lg:px-6 lg:py-3"
            >
              Date
            </th>
            <th
              scope="col"
              className="px-2 py-1 sm:px-3 sm:py-1.5 md:px-4 md:py-2 lg:px-6 lg:py-3"
            >
              Description
            </th>
          </tr>
        </thead>
        <tbody>{children}</tbody>
      </table>
    </>
  );
}

export default function Entries({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  const childrenArray = React.Children.toArray(children);
  const firstEntry = childrenArray[0];
  const previousEntries = childrenArray.slice(1);

  if (!React.isValidElement(firstEntry)) {
    throw new Error("First child is not a valid React element");
  }

  const { version, date, children: firstEntryChildren } = firstEntry.props;

  return (
    <div className="relative overflow-x-auto p-4 md:p-6 xl:p-8">
      <Latest title={title} version={version} date={date}>
        {firstEntryChildren}
      </Latest>
      <Previous title={title}>{previousEntries}</Previous>
    </div>
  );
}
