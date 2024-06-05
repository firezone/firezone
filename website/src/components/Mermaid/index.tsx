import React, {useEffect} from 'react';
import mermaid from 'mermaid';

mermaid.initialize({
    startOnLoad: true,
    theme: 'default',
});

type MermaidProps = {
    chart: string;
};

const Mermaid: React.FC<MermaidProps> = ({
    chart, ...mermaidOptions}) => {

    useEffect (() => {
        mermaid.contentLoaded();
    }, []);

    return (<div className="mermaid">{chart}</div>);
};

export default Mermaid;
