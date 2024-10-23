"use client";

import { ReactNode, useState } from "react";
import { HiCloud, HiMiniPuzzlePiece, HiLockClosed } from "react-icons/hi2";
import { SlideIn } from "@/components/Animations";
import ActionLink from "../ActionLink";
import { Route } from "next";

interface SingleFeatureProps {
  title: string;
  boldedTitle?: string;
  desc: string;
  link: URL | Route<string>;
  buttonDesc: string;
  children: React.ReactNode;
}

export default function SingleFeature({
  title,
  boldedTitle,
  desc,
  link,
  buttonDesc,
  children,
}: SingleFeatureProps) {
  return (
    <div className="flex w-full justify-between items-center">
      {children}
      <div className="flex flex-col w-full h-full justify-between lg:w-[480px] xl:w-[580px]">
        <div className="mb-4 text-3xl md:text-4xl lg:text-5xl ">
          <h6 className="uppercase text-sm font-semibold text-primary-450 tracking-wide mb-2">
            Stay Connected
          </h6>
          <h3 className=" text-pretty text-left tracking-tight font-bold inline-block">
            {title}
            <span className="text-primary-450"> {boldedTitle}</span>
          </h3>
        </div>
        <div className="max-w-screen-md">
          <p className="text-md text-left text-pretty mb-12 text-neutral-600 font-medium">
            {desc}
          </p>
          <ActionLink
            color="neutral-900"
            transitionColor="primary-450"
            size="lg"
            href={link}
          >
            {buttonDesc}
          </ActionLink>
        </div>
      </div>
    </div>
  );
}
