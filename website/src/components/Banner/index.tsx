import Link from "next/link";
import Image from "next/image";

export default function Banner() {
  return (
    <Link href="/blog">
      <div className="hover:text-primary-450 transition-all duration-50 ease-in-out invert-0 flex gap-2 mb-5 items-center rounded-full p-1.5 text-neutral-400 bg-[rgba(255,255,255,0.02)] shadow-[inset_0_-8px_11px_0_rgba(255,255,255,0.05)]">
        <Image
          src="/images/play-icon.png"
          width="24"
          height="24"
          alt="Play Icon"
        />
        <p className="text-sm mr-4">See our latest news</p>
      </div>
    </Link>
  );
}
