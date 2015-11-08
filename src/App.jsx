import React from 'react';
import SplitPane from 'react-split-pane';

export class App extends React.Component {
  render() {
    return (
      <SplitPane split="vertical" minSize="50">
        <div>Left</div>
        <SplitPane split="horizontal">
          <div>Top</div>
          <div>Bottom</div>
        </SplitPane>
      </SplitPane>
    );
  }
}
