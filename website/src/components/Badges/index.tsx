import Image from "next/image";
import Link from "next/link";

type Size = "xs" | "sm" | "md" | "lg" | "xl";

enum SizeClass {
  XS = "px-1 py-0.5 text-xs rounded-md",
  SM = "px-1.5 py-1 text-sm rounded-md",
  MD = "px-2 py-1 text-base rounded-lg",
  LG = "px-3 py-1.5 text-lg rounded-lg",
  XL = "px-4 py-2 text-xl rounded-xl",
}

export function Badge({
  children,
  size,
  bgColor,
  textColor,
}: {
  children: React.ReactNode;
  size: Size;
  bgColor: string;
  textColor: string;
}) {
  const sizeClass = SizeClass[size.toUpperCase() as keyof typeof SizeClass];

  return (
    <span
      className={`place-content-center uppercase inline-block ${sizeClass} font-semibold bg-${bgColor} text-${textColor}`}
    >
      {children}
    </span>
  );
}

export function RunaCap() {
  return (
    <Link
      href="https://runacap.com/ross-index/q2-2022/"
      target="_blank"
      rel="noopener"
    >
      <Image
        width={260}
        height={56}
        src="https://runacap.com/wp-content/uploads/2022/07/ROSS_badge_black_Q2_2022.svg"
        alt="ROSS Index - Fastest Growing Open-Source Startups in Q2 2022 | Runa Capital"
      />
    </Link>
  );
}
