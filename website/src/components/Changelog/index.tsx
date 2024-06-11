import { TabsGroup, TabsItem } from "@/components/Tabs";

enum ChangelogType {
  All,
  Gateway,
  Android,
  Apple,
  Linux,
  Windows,
}

/* I've purposefully left the mark:version sentinels out of the below data.
 * We need to add a new element to these for each released component, not
 * simply bump the version.
 */
const changelogData = {
  [ChangelogType.Gateway]: [
    {
      version: "1.0.5",
      date: new Date(),
      description: <p>This release fixes stuff</p>,
    },
    {
      version: "1.0.4",
      date: new Date(),
      description: <p>This release fixes stuff</p>,
    },
  ],
  [ChangelogType.Android]: [
    {
      version: "1.0.2",
      date: new Date(),
      description: <p>More fixing of things</p>,
    },
    {
      version: "1.0.1",
      date: new Date(),
      description: (
        <p>This release contains bug fixes and performance improvements.</p>
      ),
    },
  ],
  [ChangelogType.Apple]: [
    {
      version: "1.0.4",
      date: new Date(),
      description: (
        <p>This release contains bug fixes and performance improvements.</p>
      ),
    },
    {
      version: "1.0.3",
      date: new Date(),
      description: (
        <p>This release contains bug fixes and performance improvements.</p>
      ),
    },
  ],
  [ChangelogType.Linux]: [
    {
      version: "1.0.5",
      date: new Date(),
      description: (
        <p>This release contains bug fixes and performance improvements.</p>
      ),
    },
    {
      version: "1.0.4",
      date: new Date(),
      description: (
        <p>This release contains bug fixes and performance improvements.</p>
      ),
    },
  ],

  [ChangelogType.Windows]: [
    {
      version: "1.0.5",
      date: new Date(),
      description: (
        <p>This release contains bug fixes and performance improvements.</p>
      ),
    },
    {
      version: "1.0.4",
      date: new Date(),
      description: (
        <p>This release contains bug fixes and performance improvements.</p>
      ),
    },
  ],
};

function Item({
  version,
  date,
  description,
}: {
  version: string;
  date: Date;
  description: React.ReactNode;
}) {
  return (
    <tr>
      <td>{version}</td>
      <td>{date.toDateString()}</td>
      <td>{description}</td>
    </tr>
  );
}

function mergeAndSortChangelogData(): {
  type: ChangelogType;
  version: string;
  date: Date;
  description: React.ReactNode;
}[] {
  const allItems = Object.values(changelogData).flat();
  allItems.sort((a, b) => b.date.getTime() - a.date.getTime());
  return allItems;
}

function All(): React.ReactNode {
  // merge all the other ones and sort by date desc
  return (
    <>
      <Item type={ChangelogType.All} version="1.0.0" date={new Date()}>
        Initial release
      </Item>
      <Item type={ChangelogType.All} version="1.0.1" date={new Date()}>
        Bug fixes
      </Item>
    </>
  );
}

function Apple(): React.ReactNode {
  return (
    <>
      <Item type={ChangelogType.Apple} version="1.0.0" date={new Date()}>
        Initial release
      </Item>
      <Item type={ChangelogType.Apple} version="1.0.1" date={new Date()}>
        Bug fixes
      </Item>
    </>
  );
}

function Android(): React.ReactNode {
  return (
    <>
      <Item type={ChangelogType.Android} version="1.0.0" date={new Date()}>
        Initial release
      </Item>
      <Item type={ChangelogType.Android} version="1.0.1" date={new Date()}>
        Bug fixes
      </Item>
    </>
  );
}

function Gateway(): React.ReactNode {
  return (
    <>
      <Item type={ChangelogType.Gateway} version="1.0.0" date={new Date()}>
        Initial release
      </Item>
      <Item type={ChangelogType.Gateway} version="1.0.1" date={new Date()}>
        Bug fixes
      </Item>
    </>
  );
}

function Linux(): React.ReactNode {
  return (
    <>
      <Item type={ChangelogType.Linux} version="1.0.0" date={new Date()}>
        Initial release
      </Item>
      <Item type={ChangelogType.Linux} version="1.0.1" date={new Date()}>
        Bug fixes
      </Item>
    </>
  );
}

function Windows(): React.ReactNode {
  return (
    <>
      <Item type={ChangelogType.Windows} version="1.0.0" date={new Date()}>
        Initial release
      </Item>
      <Item type={ChangelogType.Windows} version="1.0.1" date={new Date()}>
        Bug fixes
      </Item>
    </>
  );
}

function Items({ type }: { type: ChangelogType }): React.ReactNode {
  let items: React.ReactNode;
  switch (type) {
    case ChangelogType.All:
      items = All();
      break;
    case ChangelogType.Gateway:
      items = Gateway();
      break;
    case ChangelogType.Android:
      items = Android();
      break;
    case ChangelogType.Apple:
      items = Apple();
      break;
    case ChangelogType.Linux:
      items = Linux();
      break;
    case ChangelogType.Windows:
      items = Windows();
      break;
    default:
      items = null;
  }

  return (
    <table className="w-full">
      <thead>
        <tr>
          <th className="text-left">Version</th>
          <th className="text-left">Date</th>
          <th className="text-left">Description</th>
        </tr>
      </thead>
      <tbody>{items}</tbody>
    </table>
  );
}

export default function Changelog() {
  return (
    <section className="mx-auto max-w-xl md:max-w-screen-xl">
      <TabsGroup>
        <TabsItem title="All">
          <Items type={ChangelogType.All} />
        </TabsItem>
        <TabsItem title="Gateway">
          <Items type={ChangelogType.Gateway} />
        </TabsItem>
        <TabsItem title="Android Client">
          <Items type={ChangelogType.Android} />
        </TabsItem>
        <TabsItem title="Apple Client">
          <Items type={ChangelogType.Apple} />
        </TabsItem>
        <TabsItem title="Linux Client">
          <Items type={ChangelogType.Linux} />
        </TabsItem>
        <TabsItem title="Windows Client">
          <Items type={ChangelogType.Windows} />
        </TabsItem>
      </TabsGroup>
    </section>
  );
}
