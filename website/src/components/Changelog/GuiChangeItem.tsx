import Entry from "./Entry";
import Link from "next/link";

export default function GuiChangeItem({
  enable,
  pull,
  children,
}: {
  enable: boolean;
  pull: string;
  children: React.ReactNode;
}) {
  if (!enable) {
    return null;
  }

  return (
    <li className="pl-2">
      <Link
        href={`https://github.com/firezone/firezone/pull/${pull}`}
        className="text-accent-500 underline hover:no-underline"
      >
        {`#${pull}`}
      </Link>{" "}
      {children}
    </li>
  );
}
