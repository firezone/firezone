import Image from "next/image";
import Link from "next/link";

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
