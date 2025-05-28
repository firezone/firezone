import React from "react";

const primaryColors = [
  "bg-primary-50",
  "bg-primary-100",
  "bg-primary-200",
  "bg-primary-300",
  "bg-primary-400",
  "bg-primary-450",
  "bg-primary-500",
  "bg-primary-600",
  "bg-primary-700",
  "bg-primary-800",
  "bg-primary-900",
];

const accentColors = [
  "bg-accent-50",
  "bg-accent-100",
  "bg-accent-200",
  "bg-accent-300",
  "bg-accent-400",
  "bg-accent-450",
  "bg-accent-500",
  "bg-accent-600",
  "bg-accent-700",
  "bg-accent-800",
  "bg-accent-900",
];

const neutralColors = [
  "bg-neutral-50",
  "bg-neutral-100",
  "bg-neutral-200",
  "bg-neutral-300",
  "bg-neutral-400",
  "bg-neutral-500",
  "bg-neutral-600",
  "bg-neutral-700",
  "bg-neutral-800",
  "bg-neutral-900",
];

export default function ColorPalettePage() {
  return (
    <div className="p-6 max-w-full mx-auto">
      <ColorSection title="Primary Colors" colors={primaryColors} />
      <ColorSection title="Accent Colors" colors={accentColors} />
      <ColorSection title="Neutral Colors" colors={neutralColors} />
    </div>
  );
}

function ColorSwatch({ colorClass }: { colorClass: string }) {
  return (
    <div className="bg-white rounded-lg shadow overflow-hidden border border-neutral-200">
      <div className={`h-14 ${colorClass}`}></div>
      <div className="p-3 text-xs">{colorClass}</div>
    </div>
  );
}

function ColorSection({ title, colors }: { title: string; colors: string[] }) {
  return (
    <div className="mb-8">
      <h2 className="text-xl font-semibold mb-4 pb-2 border-b border-neutral-200">
        {title}
      </h2>
      <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4">
        {colors.map((color) => (
          <ColorSwatch key={color} colorClass={color} />
        ))}
      </div>
    </div>
  );
}
