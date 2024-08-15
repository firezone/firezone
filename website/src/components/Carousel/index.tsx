import type { CustomFlowbiteTheme } from "flowbite-react";
import { Carousel as FlowbiteCarousel } from "flowbite-react";

const theme: CustomFlowbiteTheme["carousel"] = {
  root: {
    base: "relative h-full w-full",
    leftControl:
      "absolute left-0 bottom-4 flex items-end justify-center px-4 focus:outline-none",
    rightControl:
      "absolute right-0 bottom-4 flex items-end justify-center px-4 focus:outline-none",
  },
  indicators: {
    active: {
      off: "bg-white/50 hover:bg-white dark:bg-gray-800/50 dark:hover:bg-gray-800",
      on: "bg-white dark:bg-gray-800",
    },
    base: "h-3 w-3 rounded-full",
    wrapper: "absolute bottom-7 left-1/2 flex -translate-x-1/2 space-x-3",
  },
  item: {
    base: "absolute left-1/2 block w-full -translate-x-1/2",
    wrapper: {
      off: "w-full flex-shrink-0 transform cursor-default snap-center",
      on: "w-full flex-shrink-0 transform cursor-grab snap-center",
    },
  },
  control: {
    base: "inline-flex h-8 w-8 items-center justify-center rounded-full bg-white/30 group-hover:bg-white/50 group-focus:outline-none group-focus:ring-4 group-focus:ring-white dark:bg-gray-800/30 dark:group-hover:bg-gray-800/60 dark:group-focus:ring-gray-800/70 sm:h-10 sm:w-10",
    icon: "h-5 w-5 text-white dark:text-gray-800 sm:h-6 sm:w-6",
  },
  scrollContainer: {
    base: "flex h-full snap-mandatory overflow-y-hidden overflow-x-scroll scroll-smooth rounded-lg",
    snap: "snap-x",
  },
};

export default function Carousel({ children }: { children: React.ReactNode }) {
  return (
    <div className="h-96 rounded-2xl text-neutral-50 bg-[#1B1B1D]">
      <FlowbiteCarousel slideInterval={10000} pauseOnHover theme={theme}>
        {children}
      </FlowbiteCarousel>
    </div>
  );
}
