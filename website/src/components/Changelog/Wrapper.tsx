export default function Wrapper({
  title,
  version,
  notes,
  date,
  children,
}: {
  title: string;
  version: string;
  notes: React.ReactNode;
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
    <div className="relative overflow-x-auto p-4 md:p-6 xl:p-8">
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
        {notes}
      </div>
      <h3 className="text-lg md:text-xl xl:text-2xl font-semibold tracking-tight mb-4 md:mb-6 xl:mb-8 text-neutral-800">
        Previous {title} versions
      </h3>
      {children}
    </div>
  );
}
