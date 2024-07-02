import { HiXMark } from "react-icons/hi2";
import { Banner as FlowbiteBanner, BannerCollapseButton } from "flowbite-react";

export default function Banner({
  active,
  overlay,
  children,
}: {
  active: boolean;
  overlay?: boolean;
  children: React.ReactNode;
}) {
  if (!active) return null;

  return (
    <FlowbiteBanner>
      {children}
      <BannerCollapseButton className="flex items-center text-neutral-50 hover:bg-neutral-50 hover:text-neutral-900 rounded text-sm p-0.5">
        <HiXMark className="w-5 h-5" />
      </BannerCollapseButton>
    </FlowbiteBanner>
  );
}
